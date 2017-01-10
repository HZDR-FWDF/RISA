/*
 * This file is part of the RISA-library.
 *
 * Copyright (C) 2016 Helmholtz-Zentrum Dresden-Rossendorf
 *
 * RISA is free software: You can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * RISA is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with RISA. If not, see <http://www.gnu.org/licenses/>.
 *
 * Date: 30 November 2016
 * Authors: Tobias Frust <t.frust@hzdr.de>
 *
 */

#include "../DetectorInterpolation/interpolationFunctions.h"
#include "../../include/risa/Attenuation/Attenuation.h"
#include "../../include/risa/Basics/performance.h"

#include <glados/cuda/Launch.h>
#include <glados/cuda/Check.h>
#include <glados/cuda/Coordinates.h>
#include <glados/MemoryPool.h>

#include <boost/log/trivial.hpp>

#include <omp.h>
#include <iostream>
#include <cmath>
#include <fstream>
#include <iterator>
#include <exception>
#include <pthread.h>

namespace risa {
namespace cuda {

Attenuation::Attenuation(const std::string& config_file) {

   risa::read_json config_reader{};
   config_reader.read(config_file);

   if (readConfig(config_reader)) {
      throw std::runtime_error(
            "recoLib::cuda::Attenuation: Configuration file could not be loaded successfully. Please check!");
   }

   numberOfDarkFrames_ = 500;

   CHECK(cudaGetDeviceCount(&numberOfDevices_));

   //custom streams are necessary, because profiling with nvprof not possible with
   //-default-stream per-thread option
   for (auto i = 0; i < numberOfDevices_; i++) {
      CHECK(cudaSetDevice(i));
      memoryPoolIdxs_[i] =
            glados::MemoryPool<deviceManagerType>::instance()->registerStage(memPoolSize_,
                  numberOfDetectors_ * numberOfProjections_);
      cudaStream_t stream;
      CHECK(cudaStreamCreateWithPriority(&stream, cudaStreamNonBlocking, 5));
      streams_[i] = stream;
   }

   init();

   //initialize worker threads
   for (auto i = 0; i < numberOfDevices_; i++) {
      processorThreads_[i] = std::thread { &Attenuation::processor, this, i };
   }

   BOOST_LOG_TRIVIAL(debug)<< "recoLib::cuda::Attenuation: Running " << numberOfDevices_ << " Threads.";
}

Attenuation::~Attenuation() {
   for (auto idx : memoryPoolIdxs_) {
      CHECK(cudaSetDevice(idx.first));
      glados::MemoryPool<deviceManagerType>::instance()->freeMemory(idx.second);
   }
   for (auto i = 0; i < numberOfDevices_; i++) {
      CHECK(cudaSetDevice(i));
      CHECK(cudaStreamDestroy(streams_[i]));
   }
   BOOST_LOG_TRIVIAL(info)<< "recoLib::cuda::Attenuation: Destroyed.";
}

auto Attenuation::process(input_type&& sinogram) -> void {
   if (sinogram.valid()) {
      BOOST_LOG_TRIVIAL(debug)<< "Attenuation: Image arrived with Index: " << sinogram.index() << "to device " << sinogram.device();
      sinograms_[sinogram.device()].push(std::move(sinogram));
   } else {
      BOOST_LOG_TRIVIAL(debug)<< "recoLib::cuda::Attenuation: Received sentinel, finishing.";

      //send sentinal to processor thread and wait 'til it's finished
      for(auto i = 0; i < numberOfDevices_; i++) {
         sinograms_[i].push(input_type());
      }

      for(auto i = 0; i < numberOfDevices_; i++) {
         processorThreads_[i].join();
      }
      //push sentinel to results for next stage
      results_.push(output_type());
      BOOST_LOG_TRIVIAL(info) << "recoLib::cuda::Attenuation: Finished.";
   }
}

auto Attenuation::wait() -> output_type {
   return results_.take();
}

auto Attenuation::processor(const int deviceID) -> void {
   //nvtxNameOsThreadA(pthread_self(), "Attenuation");
   CHECK(cudaSetDevice(deviceID));
   auto avgDark_d = glados::cuda::make_device_ptr<float>(avgDark_.size());
   auto avgReference_d = glados::cuda::make_device_ptr<float>(
         avgReference_.size());
   auto mask_d = glados::cuda::make_device_ptr<float>(
         numberOfDetectors_ * numberOfProjections_);
   CHECK(
         cudaMemcpyAsync(avgDark_d.get(), avgDark_.data(),
               sizeof(float) * avgDark_.size(), cudaMemcpyHostToDevice,
               streams_[deviceID]));
   CHECK(
         cudaMemcpyAsync(avgReference_d.get(), avgReference_.data(),
               sizeof(float) * avgReference_.size(), cudaMemcpyHostToDevice,
               streams_[deviceID]));
   //compute mask for relevant area
   std::vector<float> mask;
   relevantAreaMask(mask);
   CHECK(
         cudaMemcpyAsync(mask_d.get(), mask.data(), sizeof(float) * mask.size(),
               cudaMemcpyHostToDevice, streams_[deviceID]));

   dim3 blocks(blockSize2D_, blockSize2D_);
   dim3 grids(std::ceil(numberOfDetectors_ / (float)blockSize2D_),
         std::ceil(numberOfProjections_ / (float)blockSize2D_));
   float temp = pow(10, -5);
   CHECK(cudaStreamSynchronize(streams_[deviceID]));
   BOOST_LOG_TRIVIAL(info)<< "recoLib::cuda::Attenuation: Running Thread for Device " << deviceID;

   while (true) {
      auto sinogram = sinograms_[deviceID].take();
      if (!sinogram.valid())
         break;
      BOOST_LOG_TRIVIAL(debug)<< "recoLib::cuda::Attenuation: Attenuationing image with Index " << sinogram.index();

      auto sino =
            glados::MemoryPool<deviceManagerType>::instance()->requestMemory(
                  memoryPoolIdxs_[deviceID]);

      computeAttenuation<<<grids, blocks, 0, streams_[deviceID]>>>(
            sinogram.container().get(), mask_d.get(), sino.container().get(),
            avgReference_d.get(), avgDark_d.get(), temp, numberOfDetectors_,
            numberOfProjections_, sinogram.plane());
      CHECK(cudaPeekAtLastError());

      sino.setIdx(sinogram.index());
      sino.setDevice(deviceID);
      sino.setPlane(sinogram.plane());
      sino.setStart(sinogram.start());

      //wait until work on device is finished
      CHECK(cudaStreamSynchronize(streams_[deviceID]));
      results_.push(std::move(sino));

      BOOST_LOG_TRIVIAL(debug)<< "recoLib::cuda::Attenuation: Attenuationing image with Index " << sinogram.index() << " finished.";
   }
}

auto Attenuation::init() -> void {
   //create filter function
   std::vector<double> filterFunction{0.5, 1.0, 1.0, 1.0, 1.5, 2.0, 3.0, 3.5, 2.0, 3.5, 3.0, 2.0, 1.5, 1.0, 1.0, 1.0, 0.5};
   double sum = std::accumulate(filterFunction.cbegin(), filterFunction.cend(), 0.0);
   std::transform(filterFunction.begin(), filterFunction.end(), filterFunction.begin(),
         std::bind1st(std::multiplies<double>(), 1.0/sum));

   //read and average reference input values
   std::vector<unsigned short> referenceValues;
   if(pathReference_.back() != '/')
      pathReference_.append("/");
   std::string refPath = pathReference_ + "ref_empty_tomograph_repaired_DetModNr_";
   readInput(refPath, referenceValues, numberOfRefFrames_);
   //interpolate reference measurement
   for(auto i = 0; i < numberOfRefFrames_*numberOfPlanes_; i++){
      std::vector<int> defectDetectors(numberOfProjections_*numberOfDetectors_);
      findDefectDetectors(referenceValues.data()+i*numberOfDetectors_*numberOfProjections_, filterFunction, defectDetectors, numberOfDetectors_, numberOfProjections_,
         threshMin_, threshMax_);
      interpolateDefectDetectors(referenceValues.data()+i*numberOfDetectors_*numberOfProjections_, defectDetectors, numberOfDetectors_, numberOfProjections_);
   }
   computeAverage(referenceValues, avgReference_);

   //read and average dark input values
   std::vector<unsigned short> darkValues;
   if(pathDark_.back() != '/')
      pathDark_.append("/");
   std::string darkPath = pathDark_ + "dark_192.168.100_DetModNr_";
   readInput(darkPath, darkValues, numberOfDarkFrames_);
   computeDarkAverage(darkValues, avgDark_);
   //interpolate dark average
   for(auto j = 0; j < numberOfPlanes_; j++){
      for(auto i = 0; i < numberOfDetectors_; i++){
         if(avgDark_[i + j * numberOfDetectors_] > 300.0){
            BOOST_LOG_TRIVIAL(info) << "Interpolating dark value at detector " << i << " in plane " << j;
            avgDark_[numberOfDetectors_ * j + i] =
                                 0.5 * (avgDark_[numberOfDetectors_ * j + (i + 1)%numberOfDetectors_] +
                                       avgDark_[numberOfDetectors_ * j + (i - 1)%numberOfDetectors_]);
         }
      }
   }
}

template <typename T>
auto Attenuation::computeDarkAverage(const std::vector<T>& values, std::vector<float>& average) -> void {
   average.resize(numberOfDetectors_*numberOfPlanes_, 0.0);
   float factor = 1.0/ (float)((float)numberOfDarkFrames_*(float)numberOfProjections_);
   factor = 0.0;
   for(auto i = 0; i < numberOfDarkFrames_; i++){
      for(auto planeInd = 0; planeInd < numberOfPlanes_; planeInd++){
         for(auto detInd = 0; detInd < numberOfDetectors_; detInd++){
            for(auto projInd = 0; projInd < numberOfProjections_; projInd++){
               const float val = (float)values[detInd + numberOfDetectors_*projInd + (i*numberOfPlanes_+planeInd)*numberOfDetectors_*numberOfProjections_];
               average[detInd + planeInd*numberOfDetectors_] += val * factor;
            }
         }
      }
   }
}

template<typename T>
auto Attenuation::computeAverage(const std::vector<T>& values,
      std::vector<float>&average) -> void {
   average.resize(numberOfProjections_ * numberOfDetectors_ * numberOfPlanes_);
   float factor = 1.0 / (float) numberOfRefFrames_;
   for (auto i = 0; i < numberOfRefFrames_; i++) {
      for (auto planeInd = 0; planeInd < numberOfPlanes_; planeInd++) {
         for (auto index = 0; index < numberOfDetectors_ * numberOfProjections_;
               index++) {
            average[index + planeInd * numberOfDetectors_ * numberOfProjections_] +=
                  values[(i + planeInd) * numberOfProjections_
                        * numberOfDetectors_ + index] * factor;
         }
      }
   }
}

template<typename T>
auto Attenuation::readDarkInputFiles(std::string& path,
      std::vector<T>& values) -> void {
   //if(path.back() != '/')
   //   path.append("/");
   std::ifstream input(path + "dark_192.168.100.fxc",
         std::ios::in | std::ios::binary);
   if (!input) {
      BOOST_LOG_TRIVIAL(error)<< "recoLib::cuda::Attenuation: Source file could not be loaded.";
      throw std::runtime_error("File could not be opened. Please check!");
   }
   //allocate memory in vector
   std::streampos fileSize;
   input.seekg(0, std::ios::end);
   fileSize = input.tellg();
   input.seekg(0, std::ios::beg);
   values.resize(numberOfDetectors_ * numberOfPlanes_);
   input.read((char*) &values[0],
         numberOfDetectors_ * numberOfPlanes_ * sizeof(T));
}

template<typename T>
auto Attenuation::readInput(std::string& path,
      std::vector<T>& values, const int numberOfFrames) -> void {
   std::vector<std::vector<T>> fileContents(numberOfDetectorModules_);
   Timer tmr1, tmr2;
   //if(path.back() != '/')
   //   path.append("/");
   tmr1.start();
   tmr2.start();
#pragma omp parallel for default(shared) //num_threads(9)
   for (auto i = 1; i <= numberOfDetectorModules_; i++) {
      std::vector<T> content;
      //TODO: make filename and ending configurable
      std::ifstream input(path + std::to_string(i) + ".fx", std::ios::in | std::ios::binary);
      if (!input) {
         BOOST_LOG_TRIVIAL(error)<< "recoLib::cuda::Attenuation: Source file " << path + std::to_string(i) + ".fx" << " could not be loaded.";
         throw std::runtime_error("File could not be opened. Please check!");
      }
      //allocate memory in vector
      std::streampos fileSize;
      input.seekg(0, std::ios::end);
      fileSize = input.tellg();
      input.seekg(0, std::ios::beg);
      content.resize(fileSize / sizeof(T));
      input.read((char*) &content[0], fileSize);
      fileContents[i - 1] = content;
   }
   tmr2.stop();
   int numberOfDetPerModule = numberOfDetectors_ / numberOfDetectorModules_;
   values.resize(fileContents[0].size() * numberOfDetectorModules_);
   for (auto i = 0; i < numberOfFrames; i++) {
      for (auto planeInd = 0; planeInd < numberOfPlanes_; planeInd++) {
         for (auto projInd = 0; projInd < numberOfProjections_; projInd++) {
            for (auto detModInd = 0; detModInd < numberOfDetectorModules_;
                  detModInd++) {
               unsigned int startIndex = projInd * numberOfDetPerModule
                     + (planeInd + i * numberOfPlanes_) * numberOfDetPerModule * numberOfProjections_;
               unsigned int indexSorted = detModInd * numberOfDetPerModule
                     + projInd * numberOfDetectors_
                     + (planeInd + i * numberOfPlanes_) * numberOfDetectors_ * numberOfProjections_;
               std::copy(fileContents[detModInd].begin() + startIndex,
                     fileContents[detModInd].begin() + startIndex
                           + numberOfDetPerModule,
                     values.begin() + indexSorted);
            }
         }
      }
   }
   tmr1.stop();
   double totalFileSize = numberOfProjections_*numberOfDetectors_*numberOfPlanes_*numberOfRefFrames_*sizeof(unsigned short)/1024.0/1024.0;
   BOOST_LOG_TRIVIAL(info)<< "recoLib::cuda::Attenuation: Reading and sorting reference input took " << tmr1.elapsed() << " s, " << totalFileSize/tmr2.elapsed() << " MByte/s.";
}

template<typename T>
auto Attenuation::relevantAreaMask(std::vector<T>& mask) -> void {
   unsigned int ya, yb, yc, yd, ye;
   unsigned int yMin, yMax;
   double lowerLimit = (lowerLimOffset_ + sourceOffset_) / 360.0;
   double upperLimit = (upperLimOffset_ + sourceOffset_) / 360.0;
   //fill whole mask with ones and mask out the unrelevant parts afterwards
   mask.resize(numberOfProjections_ * numberOfDetectors_);
   std::fill(mask.begin(), mask.end(), 1.0);

   ya = std::round(lowerLimit * numberOfProjections_);
   yb = ya;
   yc = std::round(upperLimit * numberOfProjections_);
   yd = yc;

   //slope of the straight
   double m = ((double)ya - (double)yd) / ((double)xa_ - (double)xd_);

   ye = std::round((double)yc + ((double)xe_ - (double)xc_) * m);

   for (unsigned int x = 0; x <= xa_; x++) {
      yMin = ya;
      yMax = std::round(ye + m * x);
      for (auto y = yMin; y < yMax; y++)
         mask[x + y * numberOfDetectors_] = 0.0;
   }

   for (auto x = xa_; x <= xc_; x++) {
      yMin = std::round(ya + m * (x - xa_));
      yMax = std::round(ye + m * x);
      for (auto y = yMin; y < yMax; y++)
         mask[x + y * numberOfDetectors_] = 0.0;
   }

   for (auto x = xc_; x <= xd_; x++) {
      yMin = std::round(ya + m * (x - xa_));
      yMax = yd;
      for (auto y = yMin; y < yMax; y++)
         mask[x + y * numberOfDetectors_] = 0.0;
   }

   for (auto x = xb_; x <= xf_; x++) {
      yMin = yb;
      yMax = std::round(yb + m * (x - xb_));
      for (auto y = yMin; y < yMax; y++)
         mask[x + y * numberOfDetectors_] = 0.0;
   }

   std::fill(mask.begin(),
         mask.begin() + lowerLimit * numberOfDetectors_ * numberOfProjections_,
         0.0);
   std::fill(
         mask.begin() + upperLimit * numberOfProjections_ * numberOfDetectors_,
         mask.end(), 0.0);
}

auto Attenuation::readConfig(const read_json& config_reader) -> bool {
	int sampling_rate, scan_rate;
	try {
		numberOfDetectors_ = config_reader.get_value<int>("number_of_fan_detectors");
		numberOfDetectorModules_ = config_reader.get_value<int>("number_of_det_modules");
		numberOfRefFrames_ = config_reader.get_value<int>("number_of_reference_frames");
		pathDark_ = config_reader.get_element_in_list<std::string, std::string>("inputs", "inputpath", std::make_pair("inputtype", "dark"));
		pathReference_ = config_reader.get_element_in_list<std::string, std::string>("inputs", "inputpath", std::make_pair("inputtype", "reference"));
		numberOfPlanes_ = config_reader.get_value<int>("number_of_planes");
		sampling_rate = config_reader.get_value<int>("sampling_rate");
		scan_rate = config_reader.get_value<int>("scan_rate");
		sourceOffset_ = config_reader.get_value<float>("source_offset");
		xa_ = config_reader.get_value<unsigned int>("xa");
		xb_ = config_reader.get_value<unsigned int>("xb");
		xc_ = config_reader.get_value<unsigned int>("xc");
		xd_ = config_reader.get_value<unsigned int>("xd");
		xe_ = config_reader.get_value<unsigned int>("xe");
		xf_ = config_reader.get_value<unsigned int>("xf");
		lowerLimOffset_ = config_reader.get_value<double>("lower_lim_offset");
		upperLimOffset_ = config_reader.get_value<double>("upper_lim_offset");
		blockSize2D_ = config_reader.get_value<int>("blocksize_2d_attenutation");
		memPoolSize_ = config_reader.get_value<int>("mempoolsize_attenuation");
		threshMin_ = config_reader.get_value<double>("thresh_min");
		threshMax_ = config_reader.get_value<double>("thresh_max");
	} catch (const boost::property_tree::ptree_error& e) {
		BOOST_LOG_TRIVIAL(error) << "risa::cuda:Attenuation: Failed to read config: " << e.what();
		return EXIT_FAILURE;
	}
	numberOfProjections_ = sampling_rate * 1000000 / scan_rate;
	return EXIT_SUCCESS;
}

__global__ void computeAttenuation(
      const unsigned short* __restrict__ sinogram_in,
      const float* __restrict__ mask, float* __restrict__ sinogram_out,
      const float* __restrict__ avgReference, const float* __restrict__ avgDark,
      const float temp, const int numberOfDetectors,
      const int numberOfProjections, const int planeId) {

   auto x = glados::cuda::getX();
   auto y = glados::cuda::getY();
   if (x >= numberOfDetectors || y >= numberOfProjections)
      return;

   auto sinoIndex = numberOfDetectors * y + x;

   float numerator = (float) (sinogram_in[sinoIndex])
         - avgDark[planeId * numberOfDetectors + x];

   float denominator = avgReference[planeId * numberOfDetectors * numberOfProjections + sinoIndex]
         - avgDark[planeId * numberOfDetectors + x];

   if (numerator < temp)
      numerator = temp;
   if (denominator < temp)
      denominator = temp;

   //comutes the attenuation and multiplies with mask for hiding the unrelevant region
   sinogram_out[sinoIndex] = -log(numerator / denominator) * mask[sinoIndex];

}

}
}

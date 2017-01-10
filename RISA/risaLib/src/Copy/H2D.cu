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
 * Authors: Tobias Frust (FWCC) <t.frust@hzdr.de>
 *
 */

#include "../../include/risa/Copy/H2D.h"

#include <glados/cuda/Coordinates.h>
#include <glados/cuda/Check.h>
#include <glados/MemoryPool.h>

#include <boost/log/trivial.hpp>

#include <nvToolsExt.h>

#include <exception>
#include <pthread.h>

namespace risa {
namespace cuda {

H2D::H2D(const std::string& config_file) : lastDevice_{0}, worstCaseTime_{0.0}, bestCaseTime_{std::numeric_limits<double>::max()},
      lastIndex_{0u}, lostSinos_{0u}{

   risa::read_json config_reader{};
   config_reader.read(config_file);
   if (readConfig(config_reader)) {
      throw std::runtime_error(
            "Configuration file could not be read. Please check!");
   }
   CHECK(cudaGetDeviceCount(&numberOfDevices_));

   //allocate memory on all available devices
   for (auto i = 0; i < numberOfDevices_; i++) {
      CHECK(cudaSetDevice(i));
      memoryPoolIdxs_[i] =
            glados::MemoryPool<deviceManagerType>::instance()->registerStage(memPoolSize_,
                  numberOfDetectors_ * numberOfProjections_);
      //custom streams are necessary, because profiling with nvprof seems to be
      //not possible with -default-stream per-thread option
      cudaStream_t stream;
      CHECK(cudaStreamCreateWithPriority(&stream, cudaStreamNonBlocking, 7));
      streams_[i] = stream;
   }

   //initialize worker threads
   for (auto i = 0; i < numberOfDevices_; i++) {
      processorThreads_[i] = std::thread { &H2D::processor, this, i };
   }

   BOOST_LOG_TRIVIAL(debug)<< "recoLib::cuda::H2D: Running " << numberOfDevices_ << " Threads.";
}

H2D::~H2D() {
   for (auto idx : memoryPoolIdxs_) {
      CHECK(cudaSetDevice(idx.first));
      glados::MemoryPool<deviceManagerType>::instance()->freeMemory(idx.second);
   }
   for(auto i = 0; i < numberOfDevices_; i++){
      CHECK(cudaSetDevice(i));
      CHECK(cudaStreamDestroy(streams_[i]));
   }
   BOOST_LOG_TRIVIAL(info) << "WorstCaseTime: " << worstCaseTime_ << "s; BestCaseTime: " << bestCaseTime_ << "s;";
   BOOST_LOG_TRIVIAL(info) << "Could not reconstruct " << lostSinos_ << " elements; " << lostSinos_/(double)lastIndex_*100.0 << "% loss";
}

auto H2D::process(input_type&& sinogram) -> void {
   if (sinogram.valid()) {
      if(sinogram.index() > 0)
         tmr_.stop();
      BOOST_LOG_TRIVIAL(debug) << "H2D: Image arrived with Index: " << sinogram.index() << "to device " << lastDevice_;
//      int device = sinogram.index() % 5;
//      if(device == 0) device = 1;
//      else device = 0;
      sinograms_[lastDevice_].push(std::move(sinogram));
      lastDevice_ = (lastDevice_ + 1) % numberOfDevices_;
      double time = tmr_.elapsed();
      if(sinogram.index() > 0){
         if(time < bestCaseTime_)
            bestCaseTime_ = time;
         if(time > worstCaseTime_)
            worstCaseTime_ = time;
      }
      tmr_.start();
      int diff = sinogram.index() - lastIndex_ - 1;
      lostSinos_ += diff;
      if(diff > 0)
         BOOST_LOG_TRIVIAL(debug) << "Skipping " << diff << " elements.";
      if(count_%10000 == 0)
         BOOST_LOG_TRIVIAL(info) << "Did not process " << lostSinos_ << " elements; " << lostSinos_/(double)lastIndex_*100.0 << "% loss";
      count_++;
      lastIndex_ = sinogram.index();
   } else {
      BOOST_LOG_TRIVIAL(debug)<< "recoLib::cuda::H2D: Received sentinel, finishing.";

      //send sentinel to all processor threads and wait 'til they're finished
      for(auto i = 0; i < numberOfDevices_; i++){
         sinograms_[i].push(input_type());
      }

      //wait until all threads are finished
      for(auto i = 0; i < numberOfDevices_; i++){
         processorThreads_[i].join();
      }

      //push sentinel to results for next stage
      results_.push(output_type());

      BOOST_LOG_TRIVIAL(info)<< "recoLib::cuda::H2D: Finished.";
   }
}

auto H2D::wait() -> output_type {
   return results_.take();
}

auto H2D::processor(int deviceID) -> void {
   //nvtxNameOsThreadA(pthread_self(), "H2D");
   CHECK(cudaSetDevice(deviceID));
   //for conversion from short to float
   std::vector<float> temp(numberOfProjections_*numberOfDetectors_);
   auto inputShort_d = glados::cuda::make_device_ptr<unsigned short>(numberOfProjections_*numberOfDetectors_);
   BOOST_LOG_TRIVIAL(info) << "recoLib::cuda::H2D: Running Thread for Device " << deviceID;
   while (true) {
      auto sinogram = sinograms_[deviceID].take();
      if (!sinogram.valid())
         break;

      BOOST_LOG_TRIVIAL(debug)<< "recoLib::cuda::H2D: Copy sinogram " << sinogram.index() << " to device " << deviceID;

      //copy image from device to host
      auto img = glados::MemoryPool<deviceManagerType>::instance()->requestMemory(
            memoryPoolIdxs_[deviceID]);

      CHECK(
            cudaMemcpyAsync(img.container().get(),sinogram.container().get(),
                   sinogram.size() * sizeof(unsigned short), cudaMemcpyHostToDevice, streams_[deviceID]));

      //needs to be set due to reuse of memory
      img.setIdx(sinogram.index());
      img.setDevice(deviceID);
      img.setPlane(sinogram.plane());
      img.setStart(sinogram.start());

      CHECK(cudaStreamSynchronize(streams_[deviceID]));

      //wait until work on device is finished
      results_.push(std::move(img));

      BOOST_LOG_TRIVIAL(debug)<< "recoLib::cuda::H2D: Copy sinogram " << sinogram.index() << " to device finished.";
   }
}

auto H2D::readConfig(const read_json& config_reader) -> bool {
   int sampling_rate, scan_rate;
   try {
	   numberOfDetectors_ = config_reader.get_value<int>("number_of_fan_detectors");
	   memPoolSize_ = config_reader.get_value<int>("mempoolsize_h2d");
	   sampling_rate = config_reader.get_value<int>("sampling_rate");
	   scan_rate = config_reader.get_value<int>("scan_rate");
   } catch (const boost::property_tree::ptree_error& e) {
	   BOOST_LOG_TRIVIAL(error) << "risa::cuda:H2D: Failed to read config: " << e.what();
	   return EXIT_FAILURE;
   }
   numberOfProjections_ = sampling_rate * 1000000 / scan_rate;
   return EXIT_SUCCESS;

}

}
}

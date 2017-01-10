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

#include "../../include/risa/Copy/D2H.h"

#include <glados/cuda/Check.h>
#include <glados/MemoryPool.h>

#include <boost/log/trivial.hpp>

#include <nvToolsExt.h>

#include <pthread.h>
#include <exception>

namespace risa {
namespace cuda {

D2H::D2H(const std::string& config_file) : reconstructionRate_(0), counter_(1.0){

   risa::read_json config_reader{};
   config_reader.read(config_file);
   if (readConfig(config_reader)) {
      throw std::runtime_error(
            "recoLib::cuda::D2H: unable to read config file. Please check!");
   }

   CHECK(cudaGetDeviceCount(&numberOfDevices_));

   memoryPoolIdx_ =
         glados::MemoryPool<hostManagerType>::instance()->registerStage(memPoolSize_,
               numberOfPixels_ * numberOfPixels_);

//   memoryPoolIdx_ =
//        glados::MemoryPool<hostManagerType>::instance()->registerStage(memPoolSize_,
//               256*1024);

   //custom streams are necessary, because profiling with nvprof not possible with
   //-default-stream per-thread option
   for (auto i = 0; i < numberOfDevices_; i++) {
      CHECK(cudaSetDevice(i));
      cudaStream_t stream;
      CHECK(cudaStreamCreateWithPriority(&stream, cudaStreamNonBlocking, 0));
      streams_[i] = stream;
   }

   //initialize worker threads
   for (auto i = 0; i < numberOfDevices_; i++) {
      processorThreads_[i] = std::thread { &D2H::processor, this, i };
   }
   BOOST_LOG_TRIVIAL(debug)<< "recoLib::cuda::D2H: Running " << numberOfDevices_ << " Threads.";
   tmr_.start();
}

D2H::~D2H() {
   BOOST_LOG_TRIVIAL(info) << "Reconstructed " << reconstructionRate_ << " Images/s in average.";
   glados::MemoryPool<hostManagerType>::instance()->freeMemory(memoryPoolIdx_);
   for(auto i = 0; i < numberOfDevices_; i++){
      CHECK(cudaSetDevice(i));
      CHECK(cudaStreamDestroy(streams_[i]));
   }
}

auto D2H::process(input_type&& img) -> void {
   if (img.valid()) {
      if(img.index() == 0)
         tmr_.start();
      if((count_ % 10000) == 9999){
         tmr_.stop();
         reconstructionRate_ = (reconstructionRate_*(counter_-1.0) + 10000.0/(tmr_.elapsed())) / counter_;
         counter_ += 1.0;
         BOOST_LOG_TRIVIAL(info) << "Reconstructing at " << 10000.0/(tmr_.elapsed()) << " Images/second.";
         tmr_.start();
      }
      count_++;
      BOOST_LOG_TRIVIAL(debug)<< "Image " << img.index() << "from device " << img.device() << "arrived";
      imgs_[img.device()].push(std::move(img));
   } else {
      BOOST_LOG_TRIVIAL(debug)<< "cuda::D2H: Received sentinel, finishing.";

      //send sentinal to processor threads and wait 'til they're finished
      for(auto i = 0; i < numberOfDevices_; i++) {
         imgs_[i].push(input_type());
      }

      for(auto i = 0; i < numberOfDevices_; i++) {
         processorThreads_[i].join();
      }

      //push sentinel to results for next stage
      results_.push(output_type());
      BOOST_LOG_TRIVIAL(info) << "cuda::D2H: Finished.";
   }
}

auto D2H::wait() -> output_type {
   return results_.take();
}

auto D2H::processor(const int deviceID) -> void {
   //nvtxNameOsThreadA(pthread_self(), "D2H");
   CHECK(cudaSetDevice(deviceID));
   BOOST_LOG_TRIVIAL(info) << "recoLib::cuda::D2H: Running Thread for Device " << deviceID;
   while (true) {
      auto img = imgs_[deviceID].take();
      if (!img.valid()) {
         BOOST_LOG_TRIVIAL(debug)<< "invalid image arrived.";
         break;
      }

      BOOST_LOG_TRIVIAL(debug)<< "recoLib::cuda::D2H: Copy sinogram " << img.index() << " from device " << img.device();

      //copy image from device to host
      auto ret = glados::MemoryPool<hostManagerType>::instance()->requestMemory(
            memoryPoolIdx_);
      CHECK(
            cudaMemcpyAsync(ret.container().get(), img.container().get(),
                  img.size() * sizeof(float), cudaMemcpyDeviceToHost, streams_[deviceID]));
      ret.setIdx(img.index());
      ret.setPlane(img.plane());
      ret.setStart(img.start());
      CHECK(cudaStreamSynchronize(streams_[deviceID]));

      //wait until work on device is finished
      results_.push(std::move(ret));

      BOOST_LOG_TRIVIAL(debug)<< "recoLib::cuda::D2H: Copy sinogram " << img.index() << " from device " << img.device() << " finished.";
   }
}

auto D2H::readConfig(const read_json& config_reader) -> bool {
   try {
	   numberOfPixels_ = config_reader.get_value<int>("number_of_pixels");
	   memPoolSize_ = config_reader.get_value<int>("mempoolsize_d2h");
   } catch (const boost::property_tree::ptree_error& e) {
	   BOOST_LOG_TRIVIAL(error) << "risa::cuda::D2H: Failed to read config: " << e.what();
	   return EXIT_FAILURE;
   }
   return EXIT_SUCCESS;
}

}
}

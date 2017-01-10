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

#include "../../include/risa/template/Template.h"

#include <glados/cuda/Check.h>
#include <glados/MemoryPool.h>

#include <boost/log/trivial.hpp>

#include <nvToolsExt.h>

#include <pthread.h>
#include <exception>

namespace risa {
namespace cuda {

Template::Template(const std::string& configFile){

   read_json config_reader{};
   config_reader.read(configFile);
   if (!readConfig(config_reader)) {
      throw std::runtime_error(
            "recoLib::cuda::Template: unable to read config file. Please check!");
   }

   CHECK(cudaGetDeviceCount(&numberOfDevices_));

   //when MemoryPool is required, register here:
   //memoryPoolIdx_ =
   //      glados::MemoryPool<hostManagerType>::instance()->registerStage(memPoolSize_,
   //            numberOfPixels_ * numberOfPixels_);

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
      processorThreads_[i] = std::thread { &Template::processor, this, i };
   }

   BOOST_LOG_TRIVIAL(debug)<< "recoLib::cuda::Template: Running " << numberOfDevices_ << " Threads.";
}

Template::~Template() {
   //when Memorypool was used, free memory here
   //glados::MemoryPool<hostManagerType>::instance()->freeMemory(memoryPoolIdx_);
   //when use of cudaStreams, destroy them here
   //for(auto i = 0; i < numberOfDevices_; i++){
   //   CHECK(cudaSetDevice(i));
   //   CHECK(cudaStreamDestroy(streams_[i]));
   //}
}

auto Template::process(input_type&& img) -> void {
   if (img.valid()) {
      BOOST_LOG_TRIVIAL(debug)<< "risa::cuda::Template: Image " << img.index() << "from device " << img.device() << "arrived";
      imgs_[img.device()].push(std::move(img));
   } else {
      BOOST_LOG_TRIVIAL(debug)<< "risa::cuda::Template: Received sentinel, finishing.";

      //send sentinal to processor threads and wait 'til they're finished
      for(auto i = 0; i < numberOfDevices_; i++) {
         imgs_[i].push(input_type());
      }

      for(auto i = 0; i < numberOfDevices_; i++) {
         processorThreads_[i].join();
      }

      //push sentinel to results for next stage
      results_.push(output_type());
      BOOST_LOG_TRIVIAL(info) << "risa::cuda::Template: Finished.";
   }
}

auto Template::wait() -> output_type {
   return results_.take();
}

auto Template::processor(const int deviceID) -> void {
   CHECK(cudaSetDevice(deviceID));
   BOOST_LOG_TRIVIAL(info) << "recoLib::cuda::Template: Running Thread for Device " << deviceID;
   while (true) {
      auto img = imgs_[deviceID].take();
      if (!img.valid()) {
         BOOST_LOG_TRIVIAL(debug)<< "invalid image arrived.";
         break;
      }

      BOOST_LOG_TRIVIAL(debug)<< "recoLib::cuda::Template: ";

      //if necessary, request memory from MemoryPool here
      auto ret = glados::MemoryPool<hostManagerType>::instance()->requestMemory(
            memoryPoolIdx_);

      //<-- do work here -->

      //in case of a CUDA stage, synchronization needs to be done here
      //CHECK(cudaStreamSynchronize(streams_[deviceID]));

      //wait until work on device is finished
      results_.push(std::move(ret));

      BOOST_LOG_TRIVIAL(debug)<< "recoLib::cuda::Template: ";
   }
}

auto Template::readConfig(const read_json& config_reader) -> bool {
	try {
		numberOfPixels_ = config_reader.get_value<int>("number_of_pixels");
	} catch (const boost::property_tree::ptree_error& e) {
	   BOOST_LOG_TRIVIAL(error) << "risa::cuda::Template: Failed to read config: " << e.what();
	   return EXIT_FAILURE;
	}
	return EXIT_SUCCESS;
}

}
}

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

#ifndef DETECTORINTERPOLATION_H_
#define DETECTORINTERPOLATION_H_

#include <glados/Image.h>
#include <glados/cuda/DeviceMemoryManager.h>
#include <glados/cuda/HostMemoryManager.h>
#include <glados/Queue.h>
#include <glados/cuda/Memory.h>

#include "../Basics/performance.h"

#include <thread>
#include <vector>
#include <map>
#include <mutex>
#include <set>

namespace risa {
namespace cuda {

//!   This stage interpolates the defect detectors in the raw data sinogram.
class DetectorInterpolation {
public:
   using input_type = glados::Image<glados::cuda::DeviceMemoryManager<unsigned short, glados::cuda::async_copy_policy>>;
   //!< The input data type that needs to fit the output type of the previous stage
   using output_type = glados::Image<glados::cuda::DeviceMemoryManager<unsigned short, glados::cuda::async_copy_policy>>;
   //!< The output data type that needs to fit the input type of the following stage
   using deviceManagerType = glados::cuda::DeviceMemoryManager<unsigned short, glados::cuda::async_copy_policy>;

public:

   //!   Initializes everything, that needs to be done only once
   /**
    *
    *    Runs as many processor-thread as CUDA devices are available in the system. Allocates memory using the
    *    MemoryPool for all CUDA devices.
    *
    *    @param[in]  configFile  path to configuration file
    */
   DetectorInterpolation(const std::string& configFile);

   //!   Destroys everything that is not destroyed automatically
   /**
    *    Tells MemoryPool to free the allocated memory.
    *    Destroys the cudaStreams.
    */
   ~DetectorInterpolation();

   //! Pushes the sinogram to the processor-threads
   /**
    * @param[in]  sinogram input data that arrived from previous stage
    */
   auto process(input_type&& sinogram) -> void;

   //! Takes one sinogram from the output queue #results_ and transfers it to the neighbored stage.
   /**
    *    @return  the oldest sinogram in the output queue #results_
    */
   auto wait() -> output_type;

private:

   std::map<int, glados::Queue<input_type>> sinograms_; //!<  one separate input queue for each available CUDA device
   glados::Queue<output_type> results_;                 //!<  the output queue in which the processed sinograms are stored

   std::map<int, std::thread> processorThreads_;      //!<  stores the processor()-threads
   std::map<int, cudaStream_t> streams_;              //!<  stores the cudaStreams that are created once
   std::map<int, unsigned int> memoryPoolIdxs_;       //!<  stores the indeces received when regisitering in MemoryPool

   //! main data processing routine executed in its own thread for each CUDA device, that performs the data processing of this stage
   /**
    * This method takes one sinogram from the input queue #sinograms_. So far, the detector interpolation is
    * performed on the host. Thus, the data is transfered from host to device, the raw data sinogram
    * is interpolated and afterwards, transfered from device to host.
    *
    * @param[in]  deviceID specifies on which CUDA device to execute the device functions
    */
   auto processor(int deviceID) -> void;

   int numberOfDevices_;      //!<  the number of available CUDA devices in the system

   unsigned int numberOfDetectors_;    //!<  the number of detectors in the fan beam sinogram
   unsigned int numberOfProjections_;  //!<  the number of projections in the fan beam sinogram

   double threshMin_;          //!<
   double threshMax_;          //!<

   int memPoolSize_;          //!< specifies, how many elements are allocated by memory pool

   std::set<int> defects_;

   //!  Read configuration values from configuration file
   /**
    * All values needed for setting up the class are read from the config file
    * in this function.
    *
    * @param[in] configFile path to config file
    *
    * @retval  true  configuration options were read successfully
    * @retval  false configuration options could not be read successfully
    */
   auto readConfig(const std::string& configFile) -> bool;
};
}
}

#endif /* DETECTORINTERPOLATION_H_ */

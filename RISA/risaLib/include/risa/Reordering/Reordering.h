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

#ifndef REORDERING_H_
#define REORDERING_H_

#include <glados/Image.h>
#include <glados/cuda/DeviceMemoryManager.h>
#include <glados/Queue.h>
#include <glados/cuda/Memory.h>

#include <thread>
#include <map>

namespace risa {
namespace cuda {

//! This stage restructures the unordered input data received from the detector modules.
/**
 * It precomputes a hash table on device and the CUDA kernel restructures the values
 * to a raw data sinogram ordered by detectors and projections.
 */
class Reordering {
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
   Reordering(const std::string& configFile);

   //!   Destroys everything that is not destroyed automatically
   /**
    *    Tells MemoryPool to free the allocated memory.
    *    Destroys the cudaStreams.
    */
   ~Reordering();

   //! Pushes the sinogram to the processor-threads
   /**
    *    @param[in]  img   input data that arrived from previous stage
    */
   auto process(input_type&& img) -> void;

   //! Takes one sinogram from the output queue #results_ and transfers it to the neighbored stage.
   /**
    *    @return  the oldest sinogram in the output queue #results_
    */
   auto wait() -> output_type;

private:

   std::map<int, glados::Queue<input_type>> sinos_;  //!<  one separate input queue for each available CUDA device
   glados::Queue<output_type> results_;              //!<  the output queue in which the processed sinograms are stored

   std::map<int, std::thread> processorThreads_;   //!<  stores the processor()-threads
   std::map<int, cudaStream_t> streams_;           //!<  stores the cudaStreams that are created once
   std::map<int, unsigned int> memoryPoolIdxs_;    //!<  stores the indeces received when regisitering in MemoryPool

   //! main data processing routine executed in its own thread for each CUDA device, that performs the data processing of this stage
   /**
    * This method takes one sinogram from the queue. It calls the restrucutring
    * CUDA kernel in its own stream. After the computation of the restructured raw data sinogramm, the
    * sinogram is pushed into the output queue
    *
    * @param[in]  deviceID specifies on which CUDA device to execute the device functions
    */
   auto processor(int deviceID) -> void;

   //! This function creates the hash tabel that stores the relationship between the ordered and unordered values
   /**
    *
    * @param[out] the hash table on the host memory space
    */
   auto createHashTable(std::vector<int>& hashTable) -> void;

   int numberOfDevices_;               //!< the number of available CUDA devices

   int numberOfDetectorsPerModule_;    //!< the number of detectors per module
   int numberOfFanDetectors_;          //!< the number of detectors in the fan beam sinogram
   int numberOfFanProjections_;        //!< the number of projections in the fan beam sinogram
   int memPoolSize_;                   //!< the number of elements that will be allocated by the memory pool

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

#endif /* REORDERING_H_ */

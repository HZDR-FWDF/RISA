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

#ifndef D2H_H_
#define D2H_H_

#include "../Basics/performance.h"

#include <glados/Image.h>
#include <glados/cuda/DeviceMemoryManager.h>
#include <glados/cuda/HostMemoryManager.h>
#include <glados/Queue.h>
#include <glados/cuda/Memory.h>

#include <thread>
#include <map>

namespace risa {
namespace cuda {

//!	This stage transfer a data element from device to host
class D2H {
public:
	using hostManagerType = glados::cuda::HostMemoryManager<float, glados::cuda::async_copy_policy>;
	//!< The input data type that needs to fit the output type of the previous stage
	using input_type = glados::Image<glados::cuda::DeviceMemoryManager<float, glados::cuda::async_copy_policy>>;
	//!< The output data type that needs to fit the input type of the following stage
	using output_type = glados::Image<glados::cuda::HostMemoryManager<float, glados::cuda::async_copy_policy>>;

public:

   //!   Initializes everything, that needs to be done only once
   /**
    *
    *    Runs as many processor-thread as CUDA devices are available in the system. Allocates memory using the
    *    MemoryPool.
    *
    *    @param[in]  configFile  path to configuration file
    */
	D2H(const std::string& configFile);

   //!   Destroys everything that is not destroyed automatically
   /**
    *    Tells MemoryPool to free the allocated memory.
    *    Destroys the cudaStreams.
    */
	~D2H();

   //! Pushes the sinogram to the processor-threads
   /**
    * The scheduling for multi-GPU usage is done in this function.
    *
    * @param[in]  sinogram input data that arrived from previous stage
    */
	auto process(input_type&& img) -> void;

   //! Takes one sinogram from the output queue #results_ and transfers it to the neighbored stage.
   /**
    *    @return  the oldest sinogram in the output queue #results_
    */
	auto wait() -> output_type;

private:
	std::map<int, glados::Queue<input_type>> imgs_;   //!<  one separate input queue for each available CUDA device
	glados::Queue<output_type> results_;              //!<  the output queue in which the processed sinograms are stored

	std::map<int, std::thread> processorThreads_;   //!<  stores the processor()-threads
	std::map<int, cudaStream_t> streams_;           //!<  stores the cudaStreams that are created once

	unsigned int memoryPoolIdx_;                    //!<  stores the indeces received when regisitering in MemoryPool

	int memPoolSize_;                               //!<  specifies, how many elements are allocated by memory pool

	int numberOfDevices_;                           //!<  the number of available CUDA devices in the system
	int numberOfPixels_;                            //!<  the number of pixels in one direction in the reconstructed image

	std::size_t count_{0};                          //!<  counts the total number of reconstructed sinograms

	double reconstructionRate_;                     //!<  the average reconstruction rate
	double counter_;                                //!<  used for computing the average reconstruction rate

	Timer tmr_;                                     //!<  used to measure the timings

   //! main data processing routine executed in its own thread for each CUDA device, that performs the data processing of this stage
   /**
    * This method takes one image from the input queue #imgs_. The image is transfered from device to host
    * using the asynchronous cudaMemcpyAsync()-operation. The resulting host structure is pushed back into
    * the output queue #results_.
    *
    * @param[in]  deviceID specifies on which CUDA device to execute the device functions
    */
	auto processor(const int deviceID) -> void;

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

#endif /* D2H_H_ */

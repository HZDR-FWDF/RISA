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

#ifndef MASKING_H_
#define MASKING_H_

#include "../ConfigReader/read_json.hpp"

#include <glados/Image.h>
#include <glados/cuda/DeviceMemoryManager.h>
#include <glados/Queue.h>
#include <glados/cuda/Memory.h>

#include <thread>
#include <map>

namespace risa {
namespace cuda {

//! This stage multiplies a precomputed mask with the reconstructed image.
/**
 * This class represents a masking stage. It multiplies the reconstructed image with
 * a precomputed mask in a CUDA kernel, to hide irrelevant areas.
 */
class Masking {

public:
   using input_type = glados::Image<glados::cuda::DeviceMemoryManager<float, glados::cuda::async_copy_policy>>;
   //!< The input data type that needs to fit the output type of the previous stage
   using output_type = glados::Image<glados::cuda::DeviceMemoryManager<float, glados::cuda::async_copy_policy>>;
   //!< The output data type that needs to fit the input type of the following stage

public:

   //!   Initializes everything, that needs to be done only once
   /**
    *
    *    Runs as many processor-thread as CUDA devices are available in the system.
    *
    *    @param[in]  configFile  path to configuration file
    */
   Masking(const std::string& configFile);

   //!   Destroys everything that is not destroyed automatically
   /**
    *   Destroys the cudaStreams.
    */
   ~Masking();

   //! Pushes the filtered parallel beam sinogram to the processor-threads
   /**
    *    @param[in]  inp   input data that arrived from previous stage
    */
   auto process(input_type&& img) -> void;

   //! Takes one image from the output queue #results_ and transfers it to the neighbored stage.
   /**
    *    @return  the oldest reconstructed image in the output queue #results_
    */
   auto wait() -> output_type;

private:

   std::map<int, glados::Queue<input_type>> imgs_;   //!<  one separate input queue for each available CUDA device
   glados::Queue<output_type> results_;              //!<  the output queue in which the processed sinograms are stored

   std::map<int, std::thread> processorThreads_;   //!<  stores the processor()-threads
   std::map<int, cudaStream_t> streams_;           //!<  stores the cudaStreams that are created once

   //! main data processing routine executed in its own thread for each CUDA device, that performs the data processing of this stage
   /**
    * This method takes one reconstruced image from the queue. It calls the masking
    * CUDA kernel in its own stream. After the multiplication of the mask with the image, the
    * result is pushed into the output queue
    *
    * @param[in]  deviceID specifies on which CUDA device to execute the device functions
    */
   auto processor(int deviceID) -> void;

   int numberOfDevices_;                           //!<  the number of available CUDA devices in the system

   int numberOfPixels_;                            //!<  the number of pixels in the reconstruction grid in one dimension

   bool performNormalization_{true};               //!<  specifies, if the normalization via thrust shall be performed (! performance drop, so far)
   float maskingValue_{0.0};                       //!<  the value to which the masked area should be set

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
   auto readConfig(const read_json& config_reader) -> bool;
};
}
}

#endif /* CROPIMAGE_H_ */

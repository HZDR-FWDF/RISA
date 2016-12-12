/*
 * This file is part of the GLADOS-library.
 *
 * Copyright (C) 2016 Helmholtz-Zentrum Dresden-Rossendorf
 *
 * GLADOS is free software: You can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * GLADOS is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with GLADOS. If not, see <http://www.gnu.org/licenses/>.
 *
 * Date: 30 November 2016
 * Authors: Tobias Frust <t.frust@hzdr.de>
 *
 */

#ifndef GLADOS_HIS_H_
#define GLADOS_HIS_H_

#include <cstddef>
#include <cstdint>
#include <fstream>
#include <memory>
#include <stdexcept>
#include <string>
#include <type_traits>
#include <utility>

#include <boost/log/trivial.hpp>

#include "../../Image.h"

#include "HISHeader.h"

namespace glados
{
	namespace loaders
	{
		template <class MemoryManager>
		class HIS : public MemoryManager
		{
			public:
				using value_type = typename MemoryManager::value_type;
				using manager_type = MemoryManager;

			private:
				enum class Datatype : std::int32_t
				{
					tn_not_implemented = -1,
					tn_unsigned_char	= 2,
					tn_unsigned_short	= 4,
					tn_dword			= 32,
					tn_double			= 64,
					tn_float			= 128
				};

			public:
				// TODO: Implement support for more than one frame per file
				auto loadImage(const std::string& path, std::size_t index) -> Image<MemoryManager>
				{
					using empty_return = Image<MemoryManager>;
					// read file header
					auto header = HISHeader{};

					auto&& file = std::ifstream{path.c_str(), std::ios_base::binary};
					if(!file.is_open())
					{
						BOOST_LOG_TRIVIAL(warning) << "HIS loader: Could not open file " + path;
						return empty_return();
					}

					readEntry(file, header.file_type);
					readEntry(file, header.header_size);
					readEntry(file, header.header_version);
					readEntry(file, header.file_size);
					readEntry(file, header.image_header_size);
					readEntry(file, header.ulx);
					readEntry(file, header.uly);
					readEntry(file, header.brx);
					readEntry(file, header.bry);
					readEntry(file, header.number_of_frames);
					readEntry(file, header.correction);
					readEntry(file, header.integration_time);
					readEntry(file, header.type_of_numbers);
					readEntry(file, header.x);

					if(header.file_type != static_cast<std::uint16_t>(HISConst::file_id))
					{
						BOOST_LOG_TRIVIAL(warning) << "HIS loader: File " << path << " is not a valid HIS file.";
						return empty_return();
					}

					if(header.header_size != static_cast<std::uint16_t>(HISConst::file_header_size))
					{
						BOOST_LOG_TRIVIAL(warning) << "HIS loader: File header size mismatch for file " << path;
						return empty_return();
					}

					if(header.type_of_numbers == static_cast<std::int32_t>(Datatype::tn_not_implemented))
					{
						BOOST_LOG_TRIVIAL(warning) << "HIS loader: No implementation for datatype of file " << path;
						return empty_return();
					}

					// jump over image header
					auto image_header = std::unique_ptr<std::uint8_t>(new std::uint8_t[header.image_header_size]);
					readEntry(file, image_header.get(), header.image_header_size);
						// ...

					// calculate dimensions
					auto width = header.brx - header.ulx + 1u;
					auto height = header.bry - header.uly + 1u;
					auto number_of_projections  = header.number_of_frames;
					if(number_of_projections > 1)
					{
						BOOST_LOG_TRIVIAL(warning) << "HIS loader: No support for more than one projection per file";
						return empty_return();
					}

					// read image data
					auto img_buffer = MemoryManager::make_ptr(width, height);

					switch(header.type_of_numbers)
					{
						case static_cast<std::int32_t>(Datatype::tn_unsigned_char):
						{
							auto buffer = std::unique_ptr<std::uint8_t>{new std::uint8_t[width * height]};
							readEntry(file, buffer.get(), width * height * sizeof(std::uint8_t));
							readBuffer<value_type, std::uint8_t>(img_buffer.get(), buffer.get(), width, height);
							break;
						}

						case static_cast<std::int32_t>(Datatype::tn_unsigned_short):
						{
							auto buffer = std::unique_ptr<std::uint16_t>{new std::uint16_t[width * height]};
							readEntry(file, buffer.get(), width * height * sizeof(std::uint16_t));
							readBuffer<value_type, std::uint16_t>(img_buffer.get(), buffer.get(), width, height);
							break;
						}

						case static_cast<std::int32_t>(Datatype::tn_dword):
						{
							auto buffer = std::unique_ptr<std::uint32_t>{new std::uint32_t[width * height]};
							readEntry(file, buffer.get(), width * height * sizeof(std::uint32_t));
							readBuffer<value_type, std::uint32_t>(img_buffer.get(), buffer.get(), width, height);
							break;
						}

						case static_cast<std::int32_t>(Datatype::tn_double):
						{
							auto buffer = std::unique_ptr<double>{new double[width * height]};
							readEntry(file, buffer.get(), width * height * sizeof(double));
							readBuffer<value_type, double>(img_buffer.get(), buffer.get(), width, height);
							break;
						}

						case static_cast<std::int32_t>(Datatype::tn_float):
						{
							auto buffer = std::unique_ptr<float>{new float[width * height]};
							readEntry(file, buffer.get(), width * height * sizeof(float));
							readBuffer<value_type, float>(img_buffer.get(), buffer.get(), width, height);
							break;
						}

						default:
						{
							BOOST_LOG_TRIVIAL(warning) << "HIS loader: No implementation for data type of file " << path;
							return empty_return();
						}
					}

					return glados::Image<MemoryManager>(width, height, index, std::move(img_buffer));
				}

			protected:
				~HIS() = default;

			private:
				template <typename U>
				inline auto readEntry(std::ifstream& file, U& entry) -> void
				{
					file.read(reinterpret_cast<char *>(&entry), sizeof(entry));
				}

				template <typename U>
				inline auto readEntry(std::ifstream& file, U* entry, std::size_t size) -> void
				{
					file.read(reinterpret_cast<char *>(entry), static_cast<std::streamsize>(size));
				}

				template <typename Wanted, typename Actual>
				inline auto readBuffer(Wanted* dest, Actual* buf, std::uint32_t width, std::uint32_t height)
					-> typename std::enable_if<std::is_same<Wanted, Actual>::value>::type
				{
					for(auto j = 0u; j < height; ++j)
					{
						for(auto i = 0u; i < width; ++i)
							dest[i + j * width] = buf[i + j * width];
					}
				}

				template <typename Wanted, typename Actual>
				inline auto readBuffer(Wanted* dest, Actual* buf, std::uint32_t width, std::uint32_t height)
					-> typename std::enable_if<!std::is_same<Wanted, Actual>::value>::type
				{
					for(auto j = 0u; j < height; ++j)
					{
						for(auto i = 0u; i < width; ++i)
							dest[i + j * width] = Wanted(buf[i + j * width]);
					}
				}
		};
	}
}


#endif /* HIS_H_ */

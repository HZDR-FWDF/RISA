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

#ifndef PIPELINE_OUTPUTSIDE_H_
#define PIPELINE_OUTPUTSIDE_H_

#include <memory>
#include <utility>

#include "Port.h"

namespace glados
{
	namespace pipeline
	{
		template <class OutputType>
		class OutputSide
		{
			public:
				auto output(OutputType&& out) -> void
				{
					if(port_ == nullptr)
						throw std::runtime_error("OutputSide: Missing port");

					port_->forward(std::forward<OutputType&&>(out));
				}

				auto attach(std::unique_ptr<Port<OutputType>>&& port) noexcept -> void
				{
					port_ = std::move(port);
				}

			protected:
				std::unique_ptr<Port<OutputType>> port_;
		};
	}
}


#endif /* PIPELINE_OUTPUTSIDE_H_ */

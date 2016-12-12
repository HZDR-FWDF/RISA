/*
 * This file is part of the GLADOS-library.
 *
 * Copyright (C) 2016 Helmholtz-Zentrum Dresden-Rossendorf
 *
 * RISA is free software: You can redistribute it and/or modify
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
 * along with RISA. If not, see <http://www.gnu.org/licenses/>.
 *
 * Date: 30 November 2016
 * Authors: Tobias Frust <t.frust@hzdr.de>
 *
 */

#include <algorithm>
#include <iterator>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

#define BOOST_ALL_DYN_LINK
#include <boost/log/trivial.hpp>
#include <boost/filesystem.hpp>

#include <glados/Filesystem.h>

namespace glados
{
	auto readDirectory(const std::string& path) -> std::vector<std::string>
	{
		auto ret = std::vector<std::string>{};
		try
		{
			auto p = boost::filesystem::path{path};
			if(boost::filesystem::exists(p))
			{
				if(boost::filesystem::is_regular_file(p))
					throw std::runtime_error(path + " is not a directory.");
				else if(boost::filesystem::is_directory(p))
				{
					for(auto&& it = boost::filesystem::directory_iterator(p);
							it != boost::filesystem::directory_iterator(); ++it)
						ret.push_back(boost::filesystem::canonical(it->path()).string());
				}
				else
					throw std::runtime_error(path + " exists but is neither a regular file nor a directory.");
			}
			else
				throw std::runtime_error(path + " does not exist.");

		}
		catch(const boost::filesystem::filesystem_error& err)
		{
			BOOST_LOG_TRIVIAL(fatal) << path << " could not be read: " << err.what();
		}
		std::sort(std::begin(ret), std::end(ret));
		return ret;
	}

	auto createDirectory(const std::string& path) -> bool
	{
		try
		{
			auto p = boost::filesystem::path{path};
			if(boost::filesystem::exists(p))
			{
				if(boost::filesystem::is_directory(p))
					return true;
				else
					throw std::runtime_error(path + " exists but is not a directory.");
			}
			else
				return boost::filesystem::create_directories(p);
		}
		catch(const boost::filesystem::filesystem_error& err)
		{
			BOOST_LOG_TRIVIAL(fatal) << path << " could not be created: " << err.what();
			return false;
		}
	}
}


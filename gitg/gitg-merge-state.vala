/*
 * This file is part of gitg
 *
 * Copyright (C) 2026 - Contributors
 *
 * gitg is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * gitg is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with gitg. If not, see <http://www.gnu.org/licenses/>.
 */

namespace Gitg
{

public class MergeState : Object
{
	public static bool has_unresolved_conflicts(Gitg.Repository? repository)
	{
		if (repository == null)
		{
			return false;
		}

		var status_opts = Ggit.StatusOption.EXCLUDE_SUBMODULES |
		                  Ggit.StatusOption.INCLUDE_UNTRACKED |
		                  Ggit.StatusOption.RECURSE_UNTRACKED_DIRS;
		var options = new Ggit.StatusOptions(status_opts,
		                                     Ggit.StatusShow.INDEX_AND_WORKDIR,
		                                     null);
		var has_conflicts = false;

		try
		{
			repository.file_status_foreach(options, (path, flags) => {
				if ((flags & Ggit.StatusFlags.CONFLICTED) != 0)
				{
					has_conflicts = true;
					return -1;
				}

				return 0;
			});
		}
		catch {}

		return has_conflicts;
	}

	public static bool has_merge_in_progress(Gitg.Repository? repository)
	{
		if (repository == null)
		{
			return false;
		}

		return repository.get_location().get_child("MERGE_HEAD").query_exists();
	}

	public static bool head_has_merge_conflicts(Gitg.Repository? repository, Gitg.Ref? reference)
	{
		if (repository == null || reference == null)
		{
			return false;
		}

		var branch = reference as Ggit.Branch;

		if (branch == null)
		{
			return false;
		}

		try
		{
			if (!branch.is_head())
			{
				return false;
			}
		}
		catch
		{
			return false;
		}

		return has_merge_in_progress(repository) && has_unresolved_conflicts(repository);
	}
}

}

// ex:set ts=4 noet

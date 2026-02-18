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

public class GitEnvironment : Object
{
	private Settings d_settings;

	construct
	{
		d_settings = new Settings(Gitg.Config.APPLICATION_ID + ".preferences.general");

		d_settings.changed["git-client"].connect((s, key) => {
			apply();
		});

		apply();
	}

	private string path_separator()
	{
		return Gitg.Config.PLATFORM_NAME == "win32" ? ";" : ":";
	}

	private string git_executable_name()
	{
		return Gitg.Config.PLATFORM_NAME == "win32" ? "git.exe" : "git";
	}

	private string normalize_for_compare(string p)
	{
		var normalized = p.strip().replace("\\", "/");

		while (normalized.has_suffix("/"))
		{
			normalized = normalized.substring(0, normalized.length - 1);
		}

		if (Gitg.Config.PLATFORM_NAME == "win32")
		{
			normalized = normalized.down();
		}

		return normalized;
	}

	private bool same_entry(string a, string b)
	{
		return normalize_for_compare(a) == normalize_for_compare(b);
	}

	private string[] split_path(string path)
	{
		string[] ret = {};

		if (path == "")
		{
			return ret;
		}

		foreach (var entry in path.split(path_separator()))
		{
			var trimmed = entry.strip();
			if (trimmed != "")
			{
				ret += trimmed;
			}
		}

		return ret;
	}

	private string join_path(string[] entries)
	{
		return string.joinv(path_separator(), entries);
	}

	private string? get_embedded_git_bin_dir()
	{
		var libdir = PlatformSupport.get_lib_dir();
		var prefix = Path.get_dirname(Path.get_dirname(libdir));
		var bindir = Path.build_filename(prefix, "bin");
		var gitexe = Path.build_filename(bindir, git_executable_name());

		if (same_entry(bindir, "/usr/bin") || same_entry(bindir, "/usr/local/bin"))
		{
			return null;
		}

		if (FileUtils.test(gitexe, FileTest.EXISTS))
		{
			return bindir;
		}

		return null;
	}

	public void apply()
	{
		var embedded_bindir = get_embedded_git_bin_dir();
		if (embedded_bindir == null)
		{
			return;
		}

		var current = Environment.get_variable("PATH") ?? "";
		var entries = split_path(current);
		string[] filtered = {};

		foreach (var entry in entries)
		{
			if (!same_entry(entry, embedded_bindir))
			{
				filtered += entry;
			}
		}

		if (d_settings.get_string("git-client") == "embedded")
		{
			string[] with_embedded = { embedded_bindir };
			foreach (var entry in filtered)
			{
				with_embedded += entry;
			}
			filtered = with_embedded;
		}

		var updated = join_path(filtered);
		if (updated != current)
		{
			Environment.set_variable("PATH", updated, true);
		}
	}
}

}

// vi:ts=4

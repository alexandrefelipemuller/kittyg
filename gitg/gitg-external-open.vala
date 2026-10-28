/*
 * This file is part of gitg
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, see <http://www.gnu.org/licenses/>.
 */

namespace Gitg
{

public class ExternalOpen
{
	private static void spawn(string[] argv, string? cwd) throws Error
	{
		var launcher = new SubprocessLauncher(SubprocessFlags.NONE);

		if (cwd != null)
		{
			launcher.set_cwd(cwd);
		}

		launcher.spawnv(argv);
	}

	/**
	 * Open a file or folder with the default application.
	 */
	public static void open(Gtk.Window? window, File location) throws Error
	{
		Gtk.show_uri_on_window(window, location.get_uri(), Gdk.CURRENT_TIME);
	}

	/**
	 * Show a file selected in the system file manager, or open the folder
	 * itself when it is a directory.
	 */
	public static void show_in_file_manager(Gtk.Window? window, File location) throws Error
	{
		var path = location.get_path();
		var is_dir = location.query_file_type(FileQueryInfoFlags.NONE) == FileType.DIRECTORY;

		if (Config.PLATFORM_NAME == "win32")
		{
			if (is_dir)
			{
				spawn({"explorer.exe", path}, null);
			}
			else
			{
				spawn({"explorer.exe", "/select," + path}, null);
			}

			return;
		}

		if (Config.PLATFORM_NAME == "osx")
		{
			spawn(is_dir ? new string[] {"open", path} : new string[] {"open", "-R", path}, null);
			return;
		}

		var folder = is_dir ? location : location.get_parent();

		if (folder == null)
		{
			throw new IOError.NOT_FOUND("No containing folder");
		}

		Gtk.show_uri_on_window(window, folder.get_uri(), Gdk.CURRENT_TIME);
	}

	/**
	 * Open a terminal with the given folder as its working directory.
	 */
	public static void open_terminal(File folder) throws Error
	{
		var path = folder.get_path();

		if (Config.PLATFORM_NAME == "win32")
		{
			if (Environment.find_program_in_path("wt.exe") != null)
			{
				spawn({"wt.exe", "-d", path}, path);
			}
			else
			{
				spawn({"cmd.exe", "/c", "start", "", "cmd.exe"}, path);
			}

			return;
		}

		if (Config.PLATFORM_NAME == "osx")
		{
			spawn({"open", "-a", "Terminal", path}, path);
			return;
		}

		string[] candidates = {
			"x-terminal-emulator",
			"gnome-terminal",
			"kgx",
			"konsole",
			"xfce4-terminal",
			"tilix",
			"alacritty",
			"kitty",
			"xterm"
		};

		foreach (var term in candidates)
		{
			if (Environment.find_program_in_path(term) != null)
			{
				spawn({term}, path);
				return;
			}
		}

		throw new IOError.NOT_FOUND("No terminal emulator found");
	}
}

}

// ex:ts=4 noet

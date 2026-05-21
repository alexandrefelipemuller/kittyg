/*
 * This file is part of gitg
 *
 * Copyright (C) 2026 - OpenAI
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

public class Logger : Object
{
	private const string LOG_DIRNAME = "logs";
	private const string LOG_FILENAME = "kittyg.log";

	private static bool s_initialized;
	private static int s_signal_fd = -1;

	public static string log_path
	{
		owned get
		{
			return Path.build_filename(Environment.get_user_state_dir(),
			                           Gitg.Config.APPLICATION_ID,
			                           LOG_DIRNAME,
			                           LOG_FILENAME);
		}
	}

	private static void ensure_log_directory() throws Error
	{
		var dir = File.new_for_path(Path.get_dirname(log_path));

		if (!dir.query_exists())
		{
			dir.make_directory_with_parents();
		}
	}

	private static bool should_persist_glib_log(GLib.LogLevelFlags level)
	{
		return (level & (GLib.LogLevelFlags.LEVEL_WARNING |
		                 GLib.LogLevelFlags.LEVEL_CRITICAL |
		                 GLib.LogLevelFlags.LEVEL_ERROR)) != 0;
	}

	private static string level_name(GLib.LogLevelFlags level)
	{
		if ((level & GLib.LogLevelFlags.LEVEL_ERROR) != 0)
		{
			return "ERROR";
		}
		else if ((level & GLib.LogLevelFlags.LEVEL_CRITICAL) != 0)
		{
			return "CRITICAL";
		}
		else if ((level & GLib.LogLevelFlags.LEVEL_WARNING) != 0)
		{
			return "WARNING";
		}

		return "LOG";
	}

	private static void append_line(string line)
	{
		try
		{
			ensure_log_directory();

			var file = File.new_for_path(log_path);
			var stream = file.append_to(FileCreateFlags.NONE);
			var output = new DataOutputStream(stream);

			output.put_string(line);
			output.close();
		}
		catch
		{
			// Do not emit new log messages from the logger itself.
		}
	}

	private static void append_event(string category, string message)
	{
		var now = new DateTime.now_local();
		var line = "[%s] [%s] %s\n".printf(now.format("%Y-%m-%d %H:%M:%S"),
		                                  category,
		                                  message);
		append_line(line);
	}

	private static void on_glib_log(string? log_domain,
	                                GLib.LogLevelFlags log_level,
	                                string message)
	{
		if (should_persist_glib_log(log_level))
		{
			var domain = log_domain ?? "GLib";
			append_event(level_name(log_level), "[%s] %s".printf(domain, message));
		}

		GLib.Log.default_handler(log_domain, log_level, message);
	}

	private static void on_fatal_signal(int signum)
	{
		if (s_signal_fd != -1)
		{
			string message = "\n[FATAL] kittyg terminated by ";

			switch (signum)
			{
			case Posix.Signal.ABRT:
				message += "SIGABRT\n";
				break;
			case Posix.Signal.BUS:
				message += "SIGBUS\n";
				break;
			case Posix.Signal.FPE:
				message += "SIGFPE\n";
				break;
			case Posix.Signal.ILL:
				message += "SIGILL\n";
				break;
			case Posix.Signal.SEGV:
				message += "SIGSEGV\n";
				break;
			case Posix.Signal.TRAP:
				message += "SIGTRAP\n";
				break;
			default:
				message += "signal\n";
				break;
			}

			Posix.write(s_signal_fd, message.data, (size_t)message.length);
		}

		Posix.signal(signum, Posix.SIG_DFL);
		Posix.raise(signum);
	}

	private static void install_signal_handler(int signum)
	{
		Posix.signal(signum, on_fatal_signal);
	}

	private static void install_signal_handlers()
	{
		try
		{
			ensure_log_directory();
			s_signal_fd = Posix.open(log_path,
			                         Posix.O_WRONLY | Posix.O_CREAT | Posix.O_APPEND,
			                         0644);
		}
		catch
		{
			s_signal_fd = -1;
			return;
		}

		if (s_signal_fd == -1)
		{
			return;
		}

		install_signal_handler(Posix.Signal.ABRT);
		install_signal_handler(Posix.Signal.BUS);
		install_signal_handler(Posix.Signal.FPE);
		install_signal_handler(Posix.Signal.ILL);
		install_signal_handler(Posix.Signal.SEGV);
		install_signal_handler(Posix.Signal.TRAP);
	}

	public static void initialize()
	{
		if (s_initialized)
		{
			return;
		}

		s_initialized = true;

		try
		{
			ensure_log_directory();
			GLib.Log.set_default_handler(on_glib_log);
			install_signal_handlers();
			append_event("INFO", "kittyg started");
		}
		catch
		{
			// Keep application startup resilient even if logging cannot be initialized.
		}
	}

	public static void log_event(string category, string message)
	{
		append_event(category, message);
	}

	public static void log_commit_failure(string stage, string message)
	{
		append_event("COMMIT", "%s: %s".printf(stage, message));
	}
}

}

// ex:set ts=4 noet

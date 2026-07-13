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
	private const int64 MAX_LOG_SIZE_BYTES = 1024 * 1024;
	private const int MAX_LOG_BACKUPS = 4;
	private const uint HEARTBEAT_INTERVAL_SECONDS = 1;
	private const int64 ANR_THRESHOLD_USEC = 15 * 1000 * 1000;
	private const int64 ANR_RECOVERY_USEC = 3 * 1000 * 1000;

	private static bool s_initialized;
	private static int s_signal_fd = -1;
	private static Mutex s_lock;
	private static int64 s_last_main_loop_pulse_usec;
	private static int64 s_last_anr_started_usec;
	private static bool s_anr_active;

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

	private static string rotated_log_path(int index)
	{
		return "%s.%d".printf(log_path, index);
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

	private static void close_signal_fd()
	{
		if (s_signal_fd != -1)
		{
			Posix.close(s_signal_fd);
			s_signal_fd = -1;
		}
	}

	private static void open_signal_fd()
	{
		close_signal_fd();
		s_signal_fd = Posix.open(log_path,
		                         Posix.O_WRONLY | Posix.O_CREAT | Posix.O_APPEND,
		                         0644);
	}

	private static void move_log_file(string source_path, string destination_path) throws Error
	{
		var source = File.new_for_path(source_path);

		if (!source.query_exists())
		{
			return;
		}

		var destination = File.new_for_path(destination_path);

		if (destination.query_exists())
		{
			destination.delete();
		}

		source.move(destination, FileCopyFlags.NONE);
	}

	private static int64 current_log_size() throws Error
	{
		var file = File.new_for_path(log_path);

		if (!file.query_exists())
		{
			return 0;
		}

		var info = file.query_info(FileAttribute.STANDARD_SIZE,
		                          FileQueryInfoFlags.NONE);
		return (int64)info.get_size();
	}

	private static void rotate_logs_if_needed(int64 incoming_bytes)
	{
		try
		{
			ensure_log_directory();

			if (current_log_size() + incoming_bytes <= MAX_LOG_SIZE_BYTES)
			{
				return;
			}

			close_signal_fd();

			var oldest = File.new_for_path(rotated_log_path(MAX_LOG_BACKUPS));
			if (oldest.query_exists())
			{
				oldest.delete();
			}

			for (var i = MAX_LOG_BACKUPS - 1; i >= 1; i--)
			{
				move_log_file(rotated_log_path(i), rotated_log_path(i + 1));
			}

			move_log_file(log_path, rotated_log_path(1));
			open_signal_fd();
		}
		catch
		{
			// Do not emit new log messages from the logger itself.
		}
	}

	private static void append_line(string line)
	{
		s_lock.lock();

		try
		{
			ensure_log_directory();
			rotate_logs_if_needed((int64)line.length);

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
		finally
		{
			s_lock.unlock();
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

	private static void note_main_loop_pulse()
	{
		s_lock.lock();
		s_last_main_loop_pulse_usec = GLib.get_monotonic_time();
		s_lock.unlock();
	}

	private static void start_main_loop_watchdog()
	{
		note_main_loop_pulse();

		Timeout.add_seconds(HEARTBEAT_INTERVAL_SECONDS, () => {
			note_main_loop_pulse();
			return Source.CONTINUE;
		});

		try
		{
			new Thread<void *>.try("kittyg-log-watchdog", watchdog_thread);
		}
		catch
		{
			append_event("WARNING", "Failed to start ANR watchdog thread");
		}
	}

	private static void *watchdog_thread()
	{
		while (true)
		{
			Thread.usleep(HEARTBEAT_INTERVAL_SECONDS * 1000 * 1000);

			var now = GLib.get_monotonic_time();
			bool log_anr = false;
			bool log_recovery = false;
			int64 stalled_usec = 0;

			s_lock.lock();
			stalled_usec = now - s_last_main_loop_pulse_usec;

			if (!s_anr_active && stalled_usec >= ANR_THRESHOLD_USEC)
			{
				s_anr_active = true;
				s_last_anr_started_usec = s_last_main_loop_pulse_usec;
				log_anr = true;
			}
			else if (s_anr_active && stalled_usec <= ANR_RECOVERY_USEC)
			{
				s_anr_active = false;
				log_recovery = true;
			}
			s_lock.unlock();

			if (log_anr)
			{
				append_event("ANR",
				             "Main loop unresponsive for %.1f seconds".printf((double)stalled_usec / 1000000.0));
			}
			else if (log_recovery)
			{
				append_event("ANR",
				             "Main loop responsive again after %.1f seconds".printf((double)(now - s_last_anr_started_usec) / 1000000.0));
			}
		}
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
			open_signal_fd();
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
			rotate_logs_if_needed(0);
			GLib.Log.set_default_handler(on_glib_log);
			install_signal_handlers();
			start_main_loop_watchdog();
			append_event("INFO", "kittyg started");
			append_event("INFO", "Persistent log: %s".printf(log_path));
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

/*
 * This file is part of gitg
 *
 * Copyright (C) 2014 - Jesse van den Kieboom
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

public enum RemoteState
{
	DISCONNECTED,
	CONNECTING,
	CONNECTED,
	TRANSFERRING
}

public errordomain RemoteError
{
	ALREADY_CONNECTED,
	ALREADY_CONNECTING,
	ALREADY_DISCONNECTED,
	STILL_CONNECTING
}

public interface CredentialsProvider : Object
{
	public abstract Ggit.Cred? credentials(string url, string? username_from_url, Ggit.Credtype allowed_types) throws Error;
}

public class Remote : Ggit.Remote
{
	private class Callbacks : Ggit.RemoteCallbacks
	{
		private Remote d_remote;
		private Ggit.RemoteCallbacks? d_proxy;

		public delegate void TransferProgress(Ggit.TransferProgress stats);
		private TransferProgress? d_transfer_progress;

		public Callbacks(Remote remote, Ggit.RemoteCallbacks? proxy, owned TransferProgress? transfer_progress)
		{
			d_remote = remote;
			d_proxy = proxy;
			d_transfer_progress = (owned)transfer_progress;
		}

		protected override void progress(string message)
		{
			if (d_proxy != null)
			{
				d_proxy.progress(message);
			}
		}

		protected override void transfer_progress(Ggit.TransferProgress stats)
		{
			if (d_transfer_progress != null)
			{
				d_transfer_progress(stats);
			}

			if (d_proxy != null)
			{
				d_proxy.transfer_progress(stats);
			}
		}

		protected override void update_tips(string refname, Ggit.OId a, Ggit.OId b)
		{
			d_remote.tip_updated(refname, a, b);

			if (d_proxy != null)
			{
				d_proxy.update_tips(refname, a, b);
			}
		}

		protected override void completion(Ggit.RemoteCompletionType type)
		{
			if (d_proxy != null)
			{
				d_proxy.completion(type);
			}
		}

		protected override Ggit.Cred? credentials(string url, string? username_from_url, Ggit.Credtype allowed_types) throws Error
		{
			Ggit.Cred? ret = null;

			var provider = d_remote.credentials_provider;

			if (provider != null)
			{
				ret = provider.credentials(url, username_from_url, allowed_types);
			}

			if (ret == null && d_proxy != null)
			{
				ret = d_proxy.credentials(url, username_from_url, allowed_types);
			}

			return ret;
		}
	}

	private RemoteState d_state;
	private string[]? d_fetch_specs;
	private string[]? d_push_specs;
	private uint d_reset_transfer_progress_timeout;
	private double d_transfer_progress;

	private Callbacks? d_callbacks;
	private static string? s_askpass_script;

	public signal void tip_updated(string refname, Ggit.OId a, Ggit.OId b);

	public override void dispose()
	{
		if (d_reset_transfer_progress_timeout != 0)
		{
			Source.remove(d_reset_transfer_progress_timeout);
			d_reset_transfer_progress_timeout = 0;
		}

		base.dispose();
	}

	public double transfer_progress
	{
		get { return d_transfer_progress; }
	}

	public RemoteState state
	{
		get { return d_state; }
		private set
		{
			if (d_state != value)
			{
				d_state = value;
				notify_property("state");
			}
		}
	}

	private void do_reset_transfer_progress()
	{
		d_reset_transfer_progress_timeout = 0;
		d_transfer_progress = 0.0;
		notify_property("transfer-progress");
	}

	private void reset_transfer_progress(bool with_delay)
	{
		if (d_transfer_progress == 0)
		{
			return;
		}

		if (with_delay)
		{
			d_reset_transfer_progress_timeout = Timeout.add(500, () => {
				do_reset_transfer_progress();
				return false;
			});
		}
		else if (d_reset_transfer_progress_timeout == 0)
		{
			do_reset_transfer_progress();
		}
	}

	private void update_transfer_progress(Ggit.TransferProgress stats)
	{
		var total = stats.get_total_objects();
		var received = stats.get_received_objects();
		var indexed = stats.get_indexed_objects();

		d_transfer_progress = (double)(received + indexed) / (double)(total + total);
		notify_property("transfer-progress");

		if (received == total && indexed == total)
		{
			reset_transfer_progress(true);
		}
	}

	private void update_state(bool force_disconnect = false)
	{
		if (get_connected())
		{
			if (force_disconnect)
			{
				disconnect.begin((obj, res) => {
					try
					{
						disconnect.end(res);
					} catch {}
				});
			}
			else
			{
				state = RemoteState.CONNECTED;
			}
		}
		else
		{
			state = RemoteState.DISCONNECTED;
		}
	}

	public new async void connect(Ggit.Direction direction, Ggit.RemoteCallbacks? callbacks = null) throws Error
	{
		if (get_connected())
		{
			if (state != RemoteState.CONNECTED)
			{
				state = RemoteState.CONNECTED;
			}

			throw new RemoteError.ALREADY_CONNECTED("already connected");
		}
		else if (state == RemoteState.CONNECTING)
		{
			throw new RemoteError.ALREADY_CONNECTING("already connecting");
		}
		else
		{
			reset_transfer_progress(false);
		}

		state = RemoteState.CONNECTING;

		while (true)
		{
			try
			{
				d_callbacks = new Callbacks(this, callbacks, update_transfer_progress);

				yield Async.thread(() => {
					base.connect(direction, d_callbacks, null, null);
				});
			}
			catch (Error e)
			{
				d_callbacks = null;

				// NOTE: need to check the message for now in case of failed
				// http or ssh auth. This is fragile and will likely break
				// in future libgit2 releases. Please fix!
				if (e.message == "Unexpected HTTP status code: 401" ||
				    e.message == "error authenticating: Username/PublicKey combination invalid")
				{
					continue;
				}
				else
				{
					update_state();
					throw e;
				}
			}

			break;
		}

		update_state();
	}

	public new async void disconnect() throws Error
	{
		if (!get_connected())
		{
			if (state != RemoteState.DISCONNECTED)
			{
				state = RemoteState.DISCONNECTED;
			}

			throw new RemoteError.ALREADY_DISCONNECTED("already disconnected");
		}

		try
		{
			yield Async.thread(() => {
				base.disconnect();
			});
		}
		catch (Error e)
		{
			update_state();
			reset_transfer_progress(true);

			throw e;
		}

		update_state();
		reset_transfer_progress(true);
	}

	private bool use_system_git_client()
	{
		var env_client = Environment.get_variable("KITTYG_GIT_CLIENT");

		if (env_client == "system")
		{
			return true;
		}
		else if (env_client == "embedded")
		{
			return false;
		}

		try
		{
			var settings = new Settings(Gitg.Config.APPLICATION_ID + ".preferences.general");
			return settings.get_string("git-client") == "system";
		}
		catch
		{
			return false;
		}
	}

	private void emit_push_output(Ggit.RemoteCallbacks? callbacks, string? output)
	{
		if (callbacks == null || output == null || output == "")
		{
			return;
		}

		foreach (var line in output.split("\n"))
		{
			var msg = line.strip();

			if (msg != "")
			{
				callbacks.progress(msg);
			}
		}
	}

	private async void fetch_from_system_git(string?                     message,
	                                         Ggit.RemoteCallbacks?       callbacks,
	                                         Ggit.RemoteDownloadTagsType? download_tags) throws Error
	{
		var owner = get_owner();

		if (owner == null)
		{
			throw new IOError.FAILED(_("Failed to determine repository for fetch"));
		}

		var cwd_file = owner.get_workdir();

		if (cwd_file == null)
		{
			cwd_file = owner.get_location();
		}

		if (cwd_file == null || cwd_file.get_path() == null)
		{
			throw new IOError.FAILED(_("Failed to determine working directory for fetch"));
		}

		var remote_target = get_name();

		if (remote_target == null || remote_target == "")
		{
			remote_target = get_url();
		}

		if (remote_target == null || remote_target == "")
		{
			throw new IOError.FAILED(_("Failed to determine remote for fetch"));
		}

		string[] argv = {"git", "fetch", "--progress", "--prune"};

		if (download_tags != null)
		{
			switch (download_tags)
			{
				case Ggit.RemoteDownloadTagsType.NONE:
					argv += "--no-tags";
					break;
				case Ggit.RemoteDownloadTagsType.ALL:
					argv += "--tags";
					break;
				default:
					break;
			}
		}

		argv += remote_target;

		string? stdout_data = null;
		string? stderr_data = null;
		int exit_status = 0;
		var envp = build_system_git_environment();

		yield Async.thread(() => {
			Process.spawn_sync(cwd_file.get_path(),
			                   argv,
			                   envp,
			                   SpawnFlags.SEARCH_PATH,
			                   null,
			                   out stdout_data,
			                   out stderr_data,
			                   out exit_status);
		});

		emit_push_output(callbacks, stdout_data);
		emit_push_output(callbacks, stderr_data);

		if (exit_status != 0)
		{
			var msg = (stderr_data ?? "").strip();

			if (msg == "")
			{
				msg = (stdout_data ?? "").strip();
			}

			if (msg == "")
			{
				msg = _("git fetch failed with exit code %d").printf(exit_status);
			}

			throw new IOError.FAILED(msg);
		}
	}

	private string shell_quote(string value)
	{
		return "'" + value.replace("'", "'\"'\"'") + "'";
	}

	private string? resolve_askpass_executable()
	{
		try
		{
			var self_executable = FileUtils.read_link("/proc/self/exe");
			if (self_executable != null && self_executable != "")
			{
				return self_executable;
			}
		}
		catch {}

		return Environment.find_program_in_path("kittyg");
	}

	private string? ensure_askpass_script()
	{
		if (s_askpass_script != null && FileUtils.test(s_askpass_script, FileTest.EXISTS))
		{
			return s_askpass_script;
		}

		var executable = resolve_askpass_executable();
		if (executable == null || executable == "")
		{
			return null;
		}

		try
		{
			var temp_dir = DirUtils.make_tmp("kittyg-askpass-XXXXXX");
			var script_path = Path.build_filename(temp_dir, "askpass.sh");
			var script_content = "#!/bin/sh\nexec " + shell_quote(executable) + " --askpass \"$1\"\n";
			FileUtils.set_contents(script_path, script_content);

			var script_file = File.new_for_path(script_path);
			var info = new FileInfo();
			info.set_attribute_uint32(FileAttribute.UNIX_MODE, 448u); // 0700
			script_file.set_attributes_from_info(info, FileQueryInfoFlags.NONE, null);

			s_askpass_script = script_path;
			return s_askpass_script;
		}
		catch (Error e)
		{
			warning("Failed to prepare askpass helper: %s", e.message);
			return null;
		}
	}

	private string[] build_system_git_environment()
	{
		var envp = Environ.get();
		var askpass_script = ensure_askpass_script();

		if (askpass_script != null && askpass_script != "")
		{
			envp = Environ.set_variable((owned) envp, "GIT_ASKPASS", askpass_script, true);
			envp = Environ.set_variable((owned) envp, "SSH_ASKPASS", askpass_script, true);
			envp = Environ.set_variable((owned) envp, "SSH_ASKPASS_REQUIRE", "force", true);
			envp = Environ.set_variable((owned) envp, "GIT_TERMINAL_PROMPT", "0", true);
		}

		return envp;
	}

	private async void push_to_system_git(bool                  force,
	                                      string                local_ref,
	                                      string                remote_ref,
	                                      Ggit.RemoteCallbacks? callbacks) throws Error
	{
		var owner = get_owner();

		if (owner == null)
		{
			throw new IOError.FAILED(_("Failed to determine repository for push"));
		}

		var cwd_file = owner.get_workdir();

		if (cwd_file == null)
		{
			cwd_file = owner.get_location();
		}

		if (cwd_file == null || cwd_file.get_path() == null)
		{
			throw new IOError.FAILED(_("Failed to determine working directory for push"));
		}

		var remote_target = get_name();

		if (remote_target == null || remote_target == "")
		{
			remote_target = get_url();
		}

		if (remote_target == null || remote_target == "")
		{
			throw new IOError.FAILED(_("Failed to determine remote for push"));
		}

		var refspec = @"$local_ref:$remote_ref";
		string[] argv;

		if (force)
		{
			argv = {"git", "push", "--progress", "--porcelain", "--force", remote_target, refspec};
		}
		else
		{
			argv = {"git", "push", "--progress", "--porcelain", remote_target, refspec};
		}

		string? stdout_data = null;
		string? stderr_data = null;
		int exit_status = 0;
		var envp = build_system_git_environment();

		yield Async.thread(() => {
			Process.spawn_sync(cwd_file.get_path(),
			                   argv,
			                   envp,
			                   SpawnFlags.SEARCH_PATH,
			                   null,
			                   out stdout_data,
			                   out stderr_data,
			                   out exit_status);
		});

		emit_push_output(callbacks, stdout_data);
		emit_push_output(callbacks, stderr_data);

		if (exit_status != 0)
		{
			var msg = (stderr_data ?? "").strip();

			if (msg == "")
			{
				msg = (stdout_data ?? "").strip();
			}

			if (msg == "")
			{
				msg = _("git push failed with exit code %d").printf(exit_status);
			}

			throw new IOError.FAILED(msg);
		}
	}

	private async void push_to(bool force, string local_ref, string remote_ref, Ggit.RemoteCallbacks? callbacks) throws Error
	{
		state = RemoteState.TRANSFERRING;
		reset_transfer_progress(false);

		try
		{
			if (use_system_git_client())
			{
				yield push_to_system_git(force, local_ref, remote_ref, callbacks);
			}
			else
			{
				yield Async.thread(() => {
					var options = new Ggit.PushOptions();
					if (d_callbacks == null) {
						d_callbacks = new Callbacks(this, callbacks, update_transfer_progress);
					}

					options.set_remote_callbacks(d_callbacks);

					var forcemark = force ? "+": "";
					string [] push_refs = { @"$forcemark$local_ref:$remote_ref" };

					if (!base.push(push_refs, options))
					  throw new Error(0,0,"push");
				});
			}
		}
		catch (Error e)
		{
			reset_transfer_progress(true);
			throw e;
		}

		reset_transfer_progress(true);
	}

	private async void download_intern(string? message, Ggit.RemoteCallbacks? callbacks, Ggit.RemoteDownloadTagsType? download_tags) throws Error
	{
		if (use_system_git_client())
		{
			state = RemoteState.TRANSFERRING;
			reset_transfer_progress(false);

			try
			{
				yield fetch_from_system_git(message, callbacks, download_tags);
			}
			catch (Error e)
			{
				update_state();
				reset_transfer_progress(true);
				throw e;
			}

			update_state();
			reset_transfer_progress(true);
			return;
		}

		bool dis = false;

		if (!get_connected())
		{
			dis = true;
			yield connect(Ggit.Direction.FETCH, callbacks);
		}

		state = RemoteState.TRANSFERRING;
		reset_transfer_progress(false);

		try
		{
			yield Async.thread(() => {
				var options = new Ggit.FetchOptions();
				options.set_remote_callbacks(d_callbacks);
				if (download_tags != null)
					options.set_download_tags(download_tags);

				base.download(null, options);

				if (message != null)
				{
					base.update_tips(d_callbacks, true, options.get_download_tags(), message);
				}
			});
		}
		catch (Error e)
		{
			update_state(dis);
			reset_transfer_progress(true);
			throw e;
		}

		update_state(dis);
		reset_transfer_progress(true);
	}

	public new async void download(Ggit.RemoteCallbacks? callbacks = null) throws Error
	{
		yield download_intern(null, callbacks, null);
	}

	public new async void push(bool force, string local_ref, string remote_ref, Ggit.RemoteCallbacks? callbacks = null) throws Error
	{
		yield push_to(force, local_ref, remote_ref, callbacks);
	}

	public new async void fetch(string? message, Ggit.RemoteCallbacks? callbacks = null, Ggit.RemoteDownloadTagsType? download_tags = null) throws Error
	{
		var msg = message;

		if (msg == null)
		{
			var name = get_name();

			if (name == null)
			{
				name = get_url();
			}

			if (name != null)
			{
				msg = "fetch: " + name;
			}
			else
			{
				msg = "";
			}
		}

		yield download_intern(msg, callbacks, download_tags);
	}

	public string[]? fetch_specs
	{
		owned get
		{
			if (d_fetch_specs != null)
			{
				return d_fetch_specs;
			}

			try
			{
				return get_fetch_specs();
			}
			catch (Error e)
			{
				return null;
			}
		}

		set
		{
			d_fetch_specs = value;
		}
	}

	public string[]? push_specs
	{
		owned get
		{
			if (d_push_specs != null)
			{
				return d_push_specs;
			}

			try
			{
				return get_push_specs();
			}
			catch (Error e)
			{
				return null;
			}
		}

		set
		{
			d_push_specs = value;
		}
	}

	public CredentialsProvider? credentials_provider
	{
		get; set;
	}
}

}

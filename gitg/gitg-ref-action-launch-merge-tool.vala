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

class RefActionLaunchMergeTool : GitgExt.UIElement, GitgExt.Action, GitgExt.RefAction, Object
{
	private const string version = Gitg.Config.VERSION;

	public GitgExt.Application? application { owned get; construct set; }
	public GitgExt.RefActionInterface action_interface { get; construct set; }
	public Gitg.Ref reference { get; construct set; }

	public RefActionLaunchMergeTool(GitgExt.Application        application,
	                                GitgExt.RefActionInterface action_interface,
	                                Gitg.Ref                   reference)
	{
		Object(application:      application,
		       action_interface: action_interface,
		       reference:        reference);
	}

	public string id
	{
		owned get { return "/org/gnome/gitg/ref-actions/launch-merge-tool"; }
	}

	public string display_name
	{
		owned get { return _("Launch External Merge Tool"); }
	}

	public string description
	{
		owned get { return _("Open the configured merge tool to resolve merge conflicts"); }
	}

	public bool available
	{
		get { return enabled; }
	}

	public bool enabled
	{
		get { return Gitg.MergeState.head_has_merge_conflicts(application.repository, reference); }
	}

	private string? configured_tool_name()
	{
		var settings = new Settings(Gitg.Config.APPLICATION_ID + ".preferences.interface");

		if (!settings.get_boolean("use-custom-merge-tool"))
		{
			return null;
		}

		var tool = settings.get_string("external-merge-tool-name").strip();

		return tool == "" ? null : tool;
	}

	private async void launch_merge_tool() throws Error
	{
		var repo = application.repository;
		var cwd_file = repo.get_workdir();

		if (cwd_file == null)
		{
			cwd_file = repo.get_location();
		}

		if (cwd_file == null || cwd_file.get_path() == null)
		{
			throw new IOError.FAILED(_("Failed to determine repository working directory"));
		}

		string[] argv = {"git", "mergetool", "--no-prompt"};
		var tool = configured_tool_name();

		if (tool != null)
		{
			argv += "--tool";
			argv += tool;
		}

		string? stdout_data = null;
		string? stderr_data = null;
		int exit_status = 0;

		yield Gitg.Async.thread(() => {
			Process.spawn_sync(cwd_file.get_path(),
			                   argv,
			                   null,
			                   SpawnFlags.SEARCH_PATH,
			                   null,
			                   out stdout_data,
			                   out stderr_data,
			                   out exit_status);
		});

		if (exit_status != 0)
		{
			var msg = (stderr_data ?? "").strip();

			if (msg == "")
			{
				msg = (stdout_data ?? "").strip();
			}

			if (msg == "")
			{
				msg = _("git mergetool failed with exit code %d").printf(exit_status);
			}

			throw new IOError.FAILED(msg);
		}
	}

	public void activate()
	{
		var notification = new SimpleNotification(_("Launch external merge tool"));
		notification.message = _("Opening merge tool...");
		application.notifications.add(notification);

		launch_merge_tool.begin((obj, res) => {
			try
			{
				launch_merge_tool.end(res);
				notification.success(_("External merge tool finished"));
			}
			catch (Error e)
			{
				notification.error(_("Failed to launch external merge tool: %s").printf(e.message));
			}

			action_interface.refresh();
			application.repository_commits_changed();
		});
	}

	public void populate_menu(Gtk.Menu menu)
	{
		if (!enabled)
		{
			return;
		}

		var item = new Gtk.MenuItem.with_label(display_name);
		item.show();
		item.activate.connect(() => {
			activate();
		});

		menu.append(item);
	}
}

}

// ex:set ts=4 noet

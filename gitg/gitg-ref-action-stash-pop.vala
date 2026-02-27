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

class RefActionStashPop : GitgExt.UIElement, GitgExt.Action, GitgExt.RefAction, Object
{
	// Do this to pull in config.h before glib.h (for gettext...)
	private const string version = Gitg.Config.VERSION;

	public GitgExt.Application? application { owned get; construct set; }
	public GitgExt.RefActionInterface action_interface { get; construct set; }
	public Gitg.Ref reference { get; construct set; }

	public RefActionStashPop(GitgExt.Application        application,
	                         GitgExt.RefActionInterface action_interface,
	                         Gitg.Ref                   reference)
	{
		Object(application:      application,
		       action_interface: action_interface,
		       reference:        reference);
	}

	public string id
	{
		owned get { return "/org/gnome/gitg/ref-actions/stash-pop"; }
	}

	public string display_name
	{
		owned get { return _("Stash pop"); }
	}

	public string description
	{
		owned get { return _("Apply and drop the selected stash entry"); }
	}

	public bool enabled
	{
		get { return reference.parsed_name.rtype == Gitg.RefType.STASH; }
	}

	private async bool run_stash_pop() throws Error
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

		var stash_ref = reference.get_shorthand();

		if (stash_ref == null || stash_ref == "")
		{
			stash_ref = reference.get_name();
		}

		if (stash_ref == null || stash_ref == "")
		{
			throw new IOError.FAILED(_("Failed to determine stash reference"));
		}

		string[] argv = {"git", "stash", "pop", stash_ref};

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
				msg = _("git stash pop failed with exit code %d").printf(exit_status);
			}

			throw new IOError.FAILED(msg);
		}

		return true;
	}

	public void activate()
	{
		var notification = new SimpleNotification(_("Stash pop “%s”").printf(reference.get_shorthand()));
		application.notifications.add(notification);

		run_stash_pop.begin((obj, res) => {
			try
			{
				run_stash_pop.end(res);
				notification.success(_("Successfully applied stash"));
			}
			catch (Error e)
			{
				notification.error(_("Failed to apply stash: %s").printf(e.message));
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

		var item = new Gtk.MenuItem.with_mnemonic(_("Stash _pop"));
		item.show();
		item.activate.connect(() => {
			activate();
		});

		menu.append(item);
	}
}

}

// ex:set ts=4 noet

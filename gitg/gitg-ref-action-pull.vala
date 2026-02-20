/*
 * This file is part of gitg
 *
 * Copyright (C) 2026 - kittyg contributors
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

class RefActionPull : GitgExt.UIElement, GitgExt.Action, GitgExt.RefAction, Object
{
	// Do this to pull in config.h before glib.h (for gettext...)
	private const string version = Gitg.Config.VERSION;

	public GitgExt.Application? application { owned get; construct set; }
	public GitgExt.RefActionInterface action_interface { get; construct set; }
	public Gitg.Ref reference { get; construct set; }

	private Ggit.Branch? d_branch;
	private Gitg.Ref? d_upstream;
	private Gitg.Remote? d_remote;

	public RefActionPull(GitgExt.Application        application,
	                     GitgExt.RefActionInterface action_interface,
	                     Gitg.Ref                   reference)
	{
		Object(application:      application,
		       action_interface: action_interface,
		       reference:        reference);

		d_branch = reference as Ggit.Branch;
		d_upstream = upstream_reference();

		if (d_upstream != null)
		{
			d_remote = application.remote_lookup.lookup(d_upstream.parsed_name.remote_name);
		}
	}

	public string id
	{
		owned get { return "/org/gnome/gitg/ref-actions/pull"; }
	}

	public string display_name
	{
		owned get
		{
			if (d_upstream == null)
			{
				return _("Pull");
			}

			return _("Pull from “%s”").printf(d_upstream.parsed_name.shortname);
		}
	}

	public string description
	{
		owned get
		{
			return _("Fetch and merge upstream into branch “%s” without checking it out").printf(reference.parsed_name.shortname);
		}
	}

	public bool available
	{
		get
		{
			return d_branch != null && d_upstream != null && d_remote != null;
		}
	}

	public bool enabled
	{
		get
		{
			size_t ahead = 0;
			size_t behind = 0;

			if (!ahead_behind(out ahead, out behind))
			{
				return true;
			}

			return behind > 0;
		}
	}

	private Gitg.Ref? upstream_reference()
	{
		if (d_branch == null)
		{
			return null;
		}

		try
		{
			return d_branch.get_upstream() as Gitg.Ref;
		}
		catch {}

		return null;
	}

	private bool ahead_behind(out size_t ahead, out size_t behind)
	{
		ahead = 0;
		behind = 0;

		if (d_upstream == null)
		{
			return false;
		}

		try
		{
			reference.get_owner().get_ahead_behind(reference.resolve().get_target(),
			                                       d_upstream.resolve().get_target(),
			                                       out ahead,
			                                       out behind);
			return true;
		}
		catch {}

		return false;
	}

	public async bool pull()
	{
		if (!available)
		{
			return false;
		}

		var fetch = new RefActionFetch(application, action_interface, reference);

		if (!fetch.available)
		{
			return false;
		}

		if (!(yield fetch.fetch()))
		{
			return false;
		}

		d_upstream = upstream_reference();

		size_t ahead = 0;
		size_t behind = 0;

		if (ahead_behind(out ahead, out behind) && behind == 0)
		{
			var notification = new SimpleNotification(_("Pull “%s”").printf(reference.parsed_name.shortname));
			application.notifications.add(notification);
			notification.success(_("Already up to date"));
			return true;
		}

		if (d_upstream == null)
		{
			application.show_infobar(_("Failed to pull"),
			                        _("The branch does not have an upstream configured anymore."),
			                        Gtk.MessageType.ERROR);
			return false;
		}

		var merge = new RefActionMerge(application, action_interface, reference);
		var result = yield merge.merge(d_upstream);

		return result != null;
	}

	public void activate()
	{
		pull.begin((obj, res) => {
			pull.end(res);
		});
	}
}

}

// ex:set ts=4 noet

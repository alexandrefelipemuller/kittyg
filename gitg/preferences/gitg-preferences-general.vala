/*
 * This file is part of gitg
 *
 * Copyright (C) 2062 - Alberto Fanjul
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

[GtkTemplate (ui = "/org/gnome/gitg/ui/gitg-preferences-general.ui")]
public class PreferencesGeneral : Gtk.Grid, GitgExt.Preferences
{
	// Do this to pull in config.h before glib.h (for gettext...)
	private const string version = Gitg.Config.VERSION;

	[GtkChild (name = "smart_push")]
	private unowned Gtk.CheckButton d_smart_push;
	[GtkChild (name = "git_client")]
	private unowned Gtk.ComboBoxText d_git_client;
	[GtkChild (name = "author_name")]
	private unowned Gtk.Entry d_author_name;
	[GtkChild (name = "author_email")]
	private unowned Gtk.Entry d_author_email;

	private const string USER_NAME_PROP = "user.name";
	private const string USER_EMAIL_PROP = "user.email";

	private Ggit.Config? d_global_config;

	construct
	{
		var settings = new Settings(Gitg.Config.APPLICATION_ID + ".preferences.general");

		settings.bind("smart-push",
		              d_smart_push,
		              "active",
		              SettingsBindFlags.GET | SettingsBindFlags.SET);

		settings.bind("git-client",
		              d_git_client,
		              "active-id",
		              SettingsBindFlags.GET | SettingsBindFlags.SET);

		load_author();
	}

	private void load_author()
	{
		try
		{
			d_global_config = new Ggit.Config.default();
		}
		catch (Error e)
		{
			warning("Error while loading config file: %s", e.message);
			d_author_name.sensitive = false;
			d_author_email.sensitive = false;
			return;
		}

		d_author_name.text = read_global(USER_NAME_PROP);
		d_author_email.text = read_global(USER_EMAIL_PROP);

		d_author_name.activate.connect(() => { save_author(USER_NAME_PROP, d_author_name); });
		d_author_name.focus_out_event.connect(() => {
			save_author(USER_NAME_PROP, d_author_name);
			return false;
		});

		d_author_email.activate.connect(() => { save_author(USER_EMAIL_PROP, d_author_email); });
		d_author_email.focus_out_event.connect(() => {
			save_author(USER_EMAIL_PROP, d_author_email);
			return false;
		});
	}

	private string read_global(string name)
	{
		try
		{
			var value = d_global_config.snapshot().get_string(name);

			return value != null ? value.strip() : "";
		}
		catch
		{
			return "";
		}
	}

	private void save_author(string name, Gtk.Entry entry)
	{
		var value = entry.text.strip();

		if (value == read_global(name))
		{
			return;
		}

		try
		{
			if (value == "")
			{
				d_global_config.delete_entry(name);
			}
			else
			{
				d_global_config.set_string(name, value);
			}
		}
		catch (Error e)
		{
			warning("Failed to set %s in git config: %s", name, e.message);
		}
	}

	public Gtk.Widget widget
	{
		owned get
		{
			return this;
		}
	}

	public string id
	{
		owned get { return "/org/gnome/gitg/Preferences/General"; }
	}

	public string display_name
	{
		owned get { return _("General"); }
	}
}
}

// vi:ts=4

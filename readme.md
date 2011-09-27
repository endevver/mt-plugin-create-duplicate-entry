# Create Duplicate Entry, a plugin for Melody and Movable Type

This plugin provides a simple interface to duplicate an entry in the same blog
or to another blog in the same installation. All entry content (including
Custom Fields) is preserved in the duplication. Entry status can be preserved,
or entries can be marked Unpublished in the duplicated entry.


# Prerequisites

* Movable Type 4.x


# Installation

To install this plugin follow the instructions found here:

http://tinyurl.com/easy-plugin-install


# Configuration

The Create Duplicate Entry plugin has a few blog-level settings: go to the
entry originating blog and find Tools > Plugins in the navigation menu, then
Create Duplicate Entry > Settings.

* Create Duplicate Entry can be enabled on a per-blog basis; be sure to check
the Enable box to use it.

* Your new entry's publish status can be preserved when duplicated, or the
duplicated entry can always be set to Unpublished.

* The originating entry's categories can be optionally preserved in the
duplicated entry.


# Use

Be sure that Create Duplicate Entry has been enabled (in plugin Settings) for
the blog you want to use it on.

Find an existing entry you'd like to duplicate. On the Edit Entry screen in
the Publishing area of the right sidebar is a new field: Duplicate Entry To.
This field provides a drop-down selector that lists all blogs the user has
permission to post in. Select the blog you'd like to duplicate the entry to
and Save.

The entry will be duplicated to the blog you have selected (whether you've
selected the current blog or another blog in the installation), and will be
published if necessary. The entry duplication is also noted in the Activity
Log, noting both the original and destination blogs.


# License

This plugin is licensed under the same terms as Perl itself.

# Copyright

Copyright 2011, Endevver LLC. All rights reserved.

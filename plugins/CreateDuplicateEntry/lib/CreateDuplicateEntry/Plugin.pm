package CreateDuplicateEntry::Plugin;

use strict;
use warnings;

# Add the "Duplicate Entry To" field to the Edit Entry screen, and populate it
# with blogs that the user can duplicate to.
sub edit_entry_template_param {
    my ($cb, $app, $param, $tmpl) = @_;
    my $q = $app->can('query') ? $app->query : $app->param;

    # Give up if this is a new entry; only previously-saved entries can be
    # duplicated.
    return 1 if !$q->param('id');

    # Give up if this is a page; we only want to duplciate entries.
    return 1 if $q->param('_type') eq 'page';

    # Only show the Duplicate Entry To field if the plugin is enabled on this
    # blog.
    my $plugin = MT->component('createduplicateentry');
    return 1 if !$plugin->get_config_value(
        'create_duplicate_entry_enable',
        'blog:' . $app->blog->id,
    );

    # MT4 displays the "Duplicate Entry To" label to the left, while MT5
    # displays it above.
    my $label_class = 'field-top-label'
        if MT->product_version =~ /^5/;

    # We want a list of all the blogs the current use can publish to, which
    # we'll use to let the user pick where to duplicate to.
    $param->{permissive_blog_ids} = _get_permissive_blog_ids();

    # Grab the basename field. We'll append the new Duplicate Entry To field
    # directly beneath it.
    my $basename_field = $tmpl->getElementById('basename');

    my $create_duplicate_entry_field = $tmpl->createElement(
        'app:setting',
        {
            id          => 'duplicate-entry-to',
            label       => 'Duplicate Entry To',
            label_class => $label_class,
            hint        => 'Duplicate this entry to another blog.',
            show_hint   => 1,
        }
    );

    my $innerHTML = <<HTML;
<mt:Loop name="permissive_blog_ids">
    <mt:If name="__first__">
        <select name="create_duplicate_entry_in_blog_id"
            class="full-width text full"
            <mt:If tag="Version" like='/^4/'>style="width: 186px;"</mt:If>>
            <!-- The "none" option needs a value that is unlikely to be a real blog name -->
            <option value="__no_blog_selected__">None</option>
    </mt:If>

            <option value="<mt:Var name="id">"><mt:Var name="name"></option>

    <mt:If name="__last__">
        </select>
    </mt:If>
</mt:Loop>
HTML

    $create_duplicate_entry_field->innerHTML($innerHTML);
    $tmpl->insertAfter($create_duplicate_entry_field, $basename_field);

    # Add a status message indicating if a new entry has been duplicated. Use a
    # session to find the new entry we just created.
    my $session = MT->model('session')->load( $q->param('id') );
    if ($session) {
        my $duped_entry_id = $session->get('new_entry_id');
        # We only needed the session to get the new entry ID so remove it now.
        $session->remove;
    
        my $duped_entry = MT->model('entry')->load( $duped_entry_id );
        if ($duped_entry) {
            my $duped_blog = MT->model('blog')->load( $duped_entry->blog_id )
                or $app->error(
                    'The blog ID ' . $duped_entry->blog_id
                    . ' could not be loaded.'
                );

            my $new_entry_edit_url = $app->uri(
                mode => 'view',
                args => {
                    _type   => 'entry',
                    id      => $duped_entry->id,
                    blog_id => $duped_blog->id,
                },
            );

            my $new_entry = '<a target="_blank" href="' 
                . $new_entry_edit_url . '">' . $duped_entry->title
                . ' in the blog ' . $duped_blog->name . '</a>';

            my $duped_msg = $tmpl->createElement(
                'app:statusmsg',
                {
                    id    => 'entry-duplicated',
                    class => 'success',
                }
            );
            $duped_msg->innerHTML(
                "The entry has been successfully duplicated: $new_entry."
            );
            my $saved_msg = $tmpl->getElementById('saved-changes');
            $tmpl->insertBefore($duped_msg, $saved_msg);
        }
    }

    1; # Transformer callbacks should always return true.
}

# Figure out which blogs the author can send a duplicate entry to, and a
# return an array of options.
sub _get_permissive_blog_ids {
    my $app = MT->instance;

    # This is a System Administrator; they should be able to send a duplicate
    # to any blog.
    my @blogs;
    if ( $app->user->is_superuser() ) {
        @blogs = MT->model('blog')->load(
            undef,
            {
                sort      => 'name',
                direction => 'ascend',
            }
        );
    }

    # The use is not a sysadmin so we need to check that they have permission
    # to work on a blog.
    else {
        @blogs = MT->model('blog')->load(
            undef,
            {
                sort      => 'name',
                direction => 'ascend',
                join      => MT::Permission->join_on(
                    'blog_id',
                    {
                        author_id => $app->user->id,
                        # attempt to filter for postish permissions (excludes
                        # registered users who only have permission to comment
                        # for instance)
                        permissions => { like => '%post%', }
                    },
                ),
            }
        );
    }

    return \@blogs;
}

# When an entry is saved, check to see if a blog was selected to duplicate the
# entry to.
sub cms_post_save_entry {
    my ($cb, $app, $entry) = @_;

    # Grab the blog ID selected to duplicate this entry to.
    my $selected_blog_id = $app->param('create_duplicate_entry_in_blog_id');

    # Just give up if there is no blog ID selected to duplicate to.
    return 1 if (
        $selected_blog_id eq '__no_blog_selected__' # "None" was selected
        || $selected_blog_id !~ /\d+/ # Invalid; a blog ID must be numeric
    );

    # create the new entry!
    _create_entry({
        entry               => $entry,
        destination_blog_id => $selected_blog_id,
    });

    1;
}

# Create the a new entry by duplicating the current one. Copy all fields for
# this entry, as well as Custom Fields. Since categories need to be copied,
# too, we also need to create Placement records (and create categories if
# needed).
sub _create_entry {
    my ($arg_ref)    = @_;
    my $entry        = $arg_ref->{entry};
    my $dest_blog_id = $arg_ref->{destination_blog_id};
    my $app          = MT->instance;
    my $plugin       = MT->component('createduplicateentry');

    my $orig_blog = MT->model('blog')->load( $entry->blog_id );
    my $dest_blog = MT->model('blog')->load( $dest_blog_id   );

    # Clone the existing entry to create a new one. This takes care of all of
    # the fields in the `entry` and `entry_meta` datasources.
    my $new_entry = $entry->clone({
        except => {           # Don't clone certain existing values
            id          => 1, # ...so the ID will be new/unique
            created_on  => 1, # ...so the created time will be "now"
            modified_by => 1,
            modified_on => 1,
        },
    });

    # The new entry's Status may be preferred to be Unpublished based on the
    # plugin Settings.
    my $preferred_status = $plugin->get_config_value(
        'create_duplicate_entry_entry_status',
        'blog:' . $entry->blog_id,
    );
    if ($preferred_status eq 'unpublished') {
        $new_entry->status( MT::Entry::HOLD() );
    }

    # The selected blog ID is where we want the new entry to be added.
    $new_entry->blog_id( $dest_blog_id );

    $new_entry->save or die $new_entry->errstr;

    # Tags need to be copied to the new entry, too. Grab the objecttag records
    # and use those to create new ones pointing to the new entry in the
    # destination blog.
    my @objecttags = MT->model('objecttag')->load({
        object_id         => $entry->id,
        object_datasource => 'entry',
    });
    foreach my $objecttag (@objecttags) {
        my $dest_objecttag = MT->model('objecttag')->new();
        $dest_objecttag->blog_id(           $dest_blog_id      );
        $dest_objecttag->object_datasource( 'entry'            );
        $dest_objecttag->object_id(         $new_entry->id     );
        $dest_objecttag->tag_id(            $objecttag->tag_id );
        $dest_objecttag->save or die $dest_objecttag->errstr;
    }

    # Categories need to be copied as needed, too. Grab the placements tieing
    # categories in this blog to the entry in this blog. Then use those
    # placements to update the new entry.
    my @placements;
    if (
        $plugin->get_config_value(
            'create_duplicate_entry_categories',
            'blog:'.$entry->blog_id
        )
    ) {
        @placements = MT->model('placement')->load({ entry_id => $entry->id });
    }

    foreach my $placement (@placements) {
        my $orig_cat = MT->model('category')->load( $placement->category_id )
            or next;

        # Use the original category basename to determine if the category
        # exists in the destination blog.
        my $dest_cat = MT->model('category')->load({
            basename => $orig_cat->basename,
            blog_id  => $dest_blog_id,
        });

        # If there is no destination category, we need to create it by
        # duplicating the original.
        if ( !$dest_cat ) {
            $dest_cat = $orig_cat->clone({
                except => {           # Don't clone certain existing values
                    id          => 1, # ...so the ID will be new/unique
                    created_on  => 1, # ...so the created time will be "now"
                    modified_by => 1,
                    modified_on => 1,
                    parent      => 1,
                },
            });

            $dest_cat->blog_id( $dest_blog_id );
            $dest_cat->save or die $dest_cat->errstr;
        }

        # Create a placement record for the category.
        my $new_placement = MT->model('placement')->new();
        $new_placement->entry_id(    $new_entry->id         );
        $new_placement->blog_id(     $dest_blog_id          );
        $new_placement->is_primary(  $placement->is_primary );
        $new_placement->category_id( $dest_cat->id          );
        $new_placement->save or die $new_placement->errstr;

        # If this category is part of a hierarchy we need to recreate the
        # hierarchy, too.
        if ( $orig_cat->parent ) {
            my $orig_parent_cat = MT->model('category')->load({
                id => $orig_cat->parent,
            });

            my $dest_parent_cat;
            while ( $orig_parent_cat ) {
                # If there's a parent-child relationship we need to recreate it.
                # If the child is the just-created category $dest_cat, use that.
                my $dest_child_cat = defined $dest_parent_cat
                    ? $dest_parent_cat : $dest_cat;

                $dest_parent_cat = $orig_parent_cat->clone({
                    except => {           # Don't clone certain existing values
                        id          => 1, # ...so the ID will be new/unique
                        created_on  => 1, # ...so the created time will be "now"
                        modified_by => 1,
                        modified_on => 1,
                        parent      => 1,
                    },
                });

                $dest_parent_cat->blog_id( $dest_blog_id );
                $dest_parent_cat->save or die $dest_parent_cat->errstr;

                # Finally, relate the new parent and child categories.
                $dest_child_cat->parent( $dest_parent_cat->id );
                $dest_child_cat->save or die $dest_child_cat->errstr;

                # Loook for another category that is the parent of this
                # category to process next. If none is found, undef
                # $orig_parent_cat so that the while can be exited.
                $orig_parent_cat = MT->model('category')->load({
                    id => $orig_parent_cat->parent,
                })
                    or last;
            }
        }

    }

    # Note the new entry that was created in the Activity Log.
    MT->log({
        blog_id   => $dest_blog_id,
        level     => MT->model('log')->INFO(),
        author_id => $app->user->id,
        message   => 'Entry "' . $new_entry->title . '" was duplicated from '
            . 'blog "' . $orig_blog->name . '" to blog "'
            . $dest_blog->name . '."',
    });

    # Republish the new, duplicated entry at the destination blog.
    MT::Util::start_background_task(
        sub {
            $app->rebuild_entry(
                Entry             => $new_entry,
                Blog              => $dest_blog,
                BuildDependencies => 1,
            ) or return $app->publish_error();
        }
    );

    # Use a session to save the duplicated entry ID, so that a status message
    # linking to the new entry can be displayed on the Edit Entry screen.
    my $session = MT->model('session')->new();
    $session->id(    $entry->id );
    $session->kind(  'DE'       ); # DE for Duplicate Entry
    $session->start( time       );
    $session->set(   'new_entry_id', $new_entry->id );
    $session->save or die $session->errstr;
}

1;

package CreateDuplicateEntry::Plugin;

use strict;
use warnings;

# Add the "Duplicate Entry To" field to the Edit Entry screen, and populate it
# with blogs that the user can duplicate to.
sub edit_entry_template_param {
    my ($cb, $app, $param, $tmpl) = @_;

    # Give up if this is a new entry; only previously-saved entries can be
    # duplicated.
    return 1 if !$app->param('id');
    
    # Give up if this is a page; we only want to duplciate entries.
    return 1 if $app->param('_type') eq 'page';
    
    # Only show the Duplicate Entry To field if the plugin is enabled on this
    # blog.
    my $plugin = MT->component('createduplicateentry');
    return 1 if !$plugin->get_config_value(
        'create_duplicate_entry_enable', 
        'blog:' . $app->blog->id,
    );

    # We want a list of all the blogs the current use can publish to, which
    # we'll use to let the user pick where to duplicate to.
    $param->{permissive_blog_ids} = _get_permissive_blog_ids();

    # Grab the basename field. We'll append the new Duplicate Entry To field
    # directly beneath it.
    my $basename_field = $tmpl->getElementById('basename');

    my $create_duplicate_entry_field = $tmpl->createElement(
        'app:setting',
        {
            id        => 'duplicate-entry-to',
            label     => 'Duplicate Entry To',
            hint      => 'Duplicate this entry to another blog.',
            show_hint => 1,
        }
    );

    my $innerHTML = <<HTML;
<mt:Loop name="permissive_blog_ids">
    <mt:If name="__first__">
        <select name="create_duplicate_entry_in_blog_id"
            class="full-width"
            style="width: 186px;">
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
    my ($arg_ref) = @_;
    my $entry        = $arg_ref->{entry};
    my $dest_blog_id = $arg_ref->{destination_blog_id};
    my $app    = MT->instance;
    my $plugin = MT->component('createduplicateentry');

    # Check that the destination blog ID is valid. If not, give up.
    if ( !MT->model('blog')->exist({ id => $dest_blog_id}) ) {
        MT->log({
            blog_id => $entry->blog_id,
            level   => MT->model('log')->ERROR(),
            message => $plugin->name . ': the destination blog ID "' 
                . $dest_blog_id . '" is invalid; Quitting.',
        });
        return;
    }

    # Create an array of valid field names. This array is used to duplicate
    # content to new fields at the selected blog ID. Standard fields are
    # below, minus the `basename`, which is recalculated to be unique for each
    # blog automatically.
    my @fields = qw{
        allow_comments allow_pings author_id convert_breaks
        excerpt keywords status text text_more title 
    };

    # Custom fields should also be copied. Load any custom field for entries
    # in the current blog ID. Do a lookup where the blog_id is the current
    # blog and the system level (blog_id of "0").
    my @cf_fields = MT->model('field')->load({
        blog_id  => [$entry->blog_id, 0],
        obj_type => 'entry',
    });

    # Push those loaded custom fields into the fields array but *only* if the
    # custom field exists in the new blog. Do a lookup where the blog_id is
    # the current blog and the system level (blog_id of "0").
    foreach my $cf_field (@cf_fields) {
        push @fields, 'field.' . $cf_field->basename
            if MT->model('field')->exist({
                blog_id  => [$dest_blog_id, 0],
                obj_type => 'entry',
                basename => $cf_field->basename,
            });
    }

    my $new_entry = MT->model('entry')->new();

    # Use the existing entry to populate the new entry by copying data to the
    # new entry.
    foreach my $field ( @fields ) {
        $new_entry->$field( $entry->$field )
            if ($entry->$field ne '');
    }

    # The new entry's Status may be preferred to be Unpublished based on the
    # plugin Settings.
    my $preferred_status = $plugin->get_config_value(
        'create_duplicate_entry_entry_status',
        'blog:' . $entry->blog_id,
    );
    if ($preferred_status eq 'unpublished') {
        $new_entry->status( MT::Entry::HOLD() );
    }

    # If the entry is scheduled, we should copy the authored-on date and time.
    # Otherwise, just set the date/time when saving the new entry, which could
    # be later than when the original entry was created.
    if ( $entry->status == MT::Entry::FUTURE() ) {
        $new_entry->authored_on( $entry->authored_on );
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
        $dest_objecttag->blog_id( $dest_blog_id );
        $dest_objecttag->object_datasource( 'entry' );
        $dest_objecttag->object_id( $new_entry->id );
        $dest_objecttag->tag_id( $objecttag->tag_id );
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
            $dest_cat = MT->model('category')->new();

            my @cat_fields = qw { 
                allow_pings author_id class description 
                label ping_urls 
            };

            foreach my $cat_field ( @cat_fields ) {
                $dest_cat->$cat_field( $orig_cat->$cat_field )
                    if ($orig_cat->$cat_field ne '');
            }
            $dest_cat->blog_id( $dest_blog_id );
            $dest_cat->save or die $dest_cat->errstr;
        }

        # Create a placement record for the category.
        my $new_placement = MT->model('placement')->new();
        $new_placement->entry_id( $new_entry->id );
        $new_placement->blog_id(  $dest_blog_id );
        $new_placement->is_primary( $placement->is_primary );

        # Now that we have a destination category we can set the category ID.
        $new_placement->category_id( $dest_cat->id );

        $new_placement->save or die $new_placement->errstr;
    }

    # Note the new entry that was created in the Activity Log.
    my $orig_blog = MT->model('blog')->load( $entry->blog_id );
    my $new_blog  = MT->model('blog')->load( $dest_blog_id );
    MT->log({
        blog_id   => $dest_blog_id,
        level     => MT->model('log')->INFO(),
        author_id => $app->user->id,
        message   => 'Entry "' . $new_entry->title . '" was duplicated from '
            . 'blog "' . $orig_blog->name . '" to blog "' 
            . $new_blog->name . '."',
    });

    # Republish the new, duplicated entry at the destination blog.
    MT::Util::start_background_task(
        sub {
            $app->rebuild_entry(
                Entry             => $new_entry,
                Blog              => $new_blog,
                BuildDependencies => 1,
            ) or return $app->publish_error();
        }
    );
}

1;

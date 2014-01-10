package OPM::Grapher::Graphs;

# This program is open source, licensed under the PostgreSQL License.
# For license terms, see the LICENSE file.
#
# Copyright (C) 2012-2014: Open PostgreSQL Monitoring Development Group

use Mojo::Base 'Mojolicious::Controller';

use Data::Dumper;

sub show {
    my $self = shift;

    my $id = $self->param('id');

    my $dbh = $self->database;

    # Get the graph
    my $sth = $dbh->prepare(
        qq{SELECT CASE WHEN s.hostname IS NOT NULL THEN s.hostname || '::' ELSE '' END || graph AS graph,description, s.id AS id_server, s.hostname
        FROM pr_grapher.list_wh_nagios_graphs() g
        LEFT JOIN public.list_servers() s ON g.id_server = s.id
        WHERE g.id = ?});

    $sth->execute($id);
    my $graph = $sth->fetchrow_hashref;
    $sth->finish;

    # Check if it exists (this can be reach by url)
    if ( !defined $graph ) {
        $dbh->disconnect;
        return $self->render_not_found;
    }

    my $hostname = $graph->{'hostname'};

    my $graph_list = [];
    if (scalar $hostname){
        $sth = $dbh->prepare(
            qq{SELECT g.id,g.graph
            FROM public.list_servers() s
            JOIN pr_grapher.list_wh_nagios_graphs() g ON s.id = g.id_server
            WHERE s.hostname = ? AND g.id <> ?
            ORDER BY 2}
        );
        $sth->execute($hostname, $id);
        while(my ($k,$v) = $sth->fetchrow){
            push @{$graph_list}, { id => $k, graphname => $v };
        }
        $sth->finish;
    }

    $dbh->disconnect;

    $self->stash(
        graph       => $graph,
        hostname    => $hostname,
        graph_list  => $graph_list,
        is_admin    => $self->session('user_admin')
    );

    $self->render;

}

sub showservice_by_name {
    my $self         = shift;
    my $server_name  = $self->param('server');
    my $service_name = $self->param('service');
    my $dbh          = $self->database;
    my $id_service;

    my $sth = $dbh->prepare(q{
        SELECT s.id AS id_service
        FROM list_services() AS s
        JOIN list_servers() AS h ON h.id = s.id_server
        WHERE h.hostname = ?
            AND s.service = ?;
    });

    $sth->execute($server_name, $service_name);

    $id_service = $sth->fetchrow();

    $sth->finish;
    $dbh->disconnect;

    return $self->redirect_to('graphs_showservice',
        id => $id_service
    );
}

sub showservice {
    my $self       = shift;
    my $id_service = $self->param('id');
    my $dbh        = $self->database;
    my @services;
    my @graphs;
    my $hostname;

    # Get the graphs associated with the given service
    my $sth = $dbh->prepare(qq{
        SELECT g.id, CASE
            WHEN s.hostname IS NOT NULL THEN s.hostname || '::'
            ELSE ''
        END || graph AS graph,
            description, s.id AS id_server, s.hostname
        FROM pr_grapher.list_wh_nagios_graphs() g
        LEFT JOIN public.list_servers() s ON g.id_server = s.id
        WHERE g.id_service = ?
        ORDER BY  g.graph
    });

    $sth->execute($id_service);
    push @graphs => $_ while $_ = $sth->fetchrow_hashref();

    # Check if it exists (this can be reach by url)
    if ( @graphs < 1 ) {
        $dbh->disconnect;
        return $self->render_not_found;
    }

    $sth->finish;

    $hostname = $graphs[0]{'hostname'};

    if ( $graphs[0]{'id_server'} ) {
        # Get other available services from the same server
        my $sth = $dbh->prepare(qq{
            SELECT id, service
            FROM wh_nagios.list_services()
            WHERE id_server = ? AND id <> ?
            ORDER BY service
        });

        $sth->execute($graphs[0]{'id_server'}, $id_service);
        push @services => $_ while $_ = $sth->fetchrow_hashref();
        $sth->finish;
    }

    $dbh->disconnect;

    $self->stash(
        graphs   => \@graphs,
        hostname => $hostname,
        services => \@services,
        is_admin => $self->session('user_admin')
    );

    $self->render;
}

sub showserver {
    my $self     = shift;
    my $idserver = $self->param('idserver');
    my $period   = $self->param('period');
    my $dbh      = $self->database;
    my @servers;

    # Get the graphs
    my $sth = $dbh->prepare(qq{
        SELECT g.id, CASE WHEN s.hostname IS NOT NULL THEN s.hostname || '::' ELSE '' END || graph AS graph,description,s.hostname
        FROM pr_grapher.list_wh_nagios_graphs() g
        JOIN public.list_servers() s ON g.id_server = s.id
        WHERE g.id_server = ?
        ORDER BY  g.graph
    });
    $sth->execute($idserver);
    my $graphs = [];
    my $hostname;
    while ( my $graph = $sth->fetchrow_hashref() ){
        $hostname = $graph->{'hostname'} if (! defined $hostname);
        push @{$graphs}, $graph;
    }
    $sth->finish;

    # Get other available servers
    $sth = $dbh->prepare(qq{
        SELECT id, hostname
        FROM public.list_servers()
        WHERE id <> ?
        ORDER BY hostname
    });

    $sth->execute($idserver);
    push @servers => $_ while $_ = $sth->fetchrow_hashref();
    $sth->finish;

    $dbh->disconnect;

    $self->stash(
        graphs   => $graphs,
        hostname => $hostname,
        servers  => \@servers,
        is_admin => $self->session('user_admin')
    );

    $self->render;

}

sub edit {
    my $self = shift;

    my $id         = $self->param('id');
    my $e          = 0;

    my $dbh = $self->database;

    # Get the graph, and the service if a service is associated
    my $sth = $dbh->prepare(
        qq{SELECT graph, description, y1_query, y2_query,
                config::text, string_agg(id_server::text, ',') AS id_server
            FROM pr_grapher.list_wh_nagios_graphs()
            WHERE id = ?
            GROUP BY 1,2,3,4,5} );
    $sth->execute($id);
    my $graph = $sth->fetchrow_hashref;
    $sth->finish;

    # Check if it exists
    if ( !defined $graph ) {
        $dbh->disconnect;
        return $self->render_not_found;
    }

    my $id_server = $graph->{id_server};

    $self->flash('id_server', $id_server);

    # Save the form
    my $method = $self->req->method;
    if ( $method =~ m/^POST$/i ) {

        # process the input data
        my $form = $self->req->params->to_hash;

        # Action depends on the name of the button pressed
        if ( exists $form->{cancel} ) {
            $dbh->disconnect;
            return $self->redirect_to('graphs_show', id => $id);
        }

        if ( exists $form->{drop} ) {
            $dbh->disconnect;

            return $self->redirect_to('graphs_remove',
                id => $id
            );
        }

        if ( exists $form->{clone} ) {
            $dbh->disconnect;
            return $self->redirect_to('graphs_clone',
                id => $id
            );
        }

        if ( exists $form->{save} ) {
            $form->{y1_query} = '' unless defined $form->{y1_query};
            $form->{y2_query} = '' unless defined $form->{y2_query};

            if ( $form->{graph} =~ m!^\s*$! ) {
                $self->msg->error("Missing graph name");
                $e = 1;
            }

            if (   ( !scalar $id_server )
                and $form->{y1_query} =~ m!^\s*$!
                and $form->{y2_query} =~ m!^\s*$!
            ) {
                $self->msg->error("Missing query");
                $e = 1;
            }

            if ( !$e ) {

                # Prepare the configuration: save and clean the $form
                # hashref to keep only the properties, so that we can
                # use the plugin
                delete $form->{save};
                my $graph = $form->{graph};
                delete $form->{graph};
                my $description =
                    ( $form->{description} =~ m!^\s*$! )
                    ? undef
                    : $form->{description};
                delete $form->{description};
                my $y1_query =
                    ( $form->{y1_query} =~ m!^\s*$! )
                    ? undef
                    : $form->{y1_query};
                delete $form->{y1_query};
                my $y2_query =
                    ( $form->{y2_query} =~ m!^\s*$! )
                    ? undef
                    : $form->{y2_query};
                delete $form->{y2_query};

                my $props = $self->properties->validate($form);
                if ( !defined $props ) {
                    $self->msg->error(
                        "Bad input, please double check the options");
                    return $self->render;
                }

                # Save the properties actually sent
                # If a property is missing, library/grapher default value will be used
                my $json = Mojo::JSON->new;
                my $config = $json->encode( $props );

                $sth = $dbh->prepare(
                    qq{UPDATE pr_grapher.graphs
                        SET graph = ?, description = ?, y1_query = ?, y2_query = ? , config = ?
                        WHERE id = ?} );
                if (
                    !defined $sth->execute(
                        $graph,    $description, $y1_query,
                        $y2_query, $config,      $id ) )
                {
                    $self->render_exception( $dbh->errstr );
                    $sth->finish;
                    $dbh->rollback;
                    $dbh->disconnect;
                    return;
                }
                $sth->finish;

                ## Set labels for this graph
                my @labels = ( );
                if (ref $form->{'labels'} eq 'ARRAY') {
                    @labels = @{ $form->{'labels'} };
                }
                else {
                    push @labels => $form->{'labels'};
                }

                $sth = $dbh->prepare(qq{
                    SELECT pr_grapher.update_graph_labels(?, ?)
                });

                if ( !defined $sth->execute( $id, \@labels) ) {
                    $self->render_exception( $dbh->errstr );
                    $sth->finish;
                    $dbh->rollback;
                    $dbh->disconnect;
                    return;
                }
                $sth->finish;

                $self->msg->info("Graph saved");
                $dbh->disconnect;
                return $self->redirect_to('graphs_show', id => $id);
            }
        }

        $self->render;
    }

    if ( !$e ) {

        $sth = $dbh->prepare(
            qq{
                SELECT l.id_service, l.id_label, l.label, l.unit,
                    l.available AS checked, s.service
                FROM pr_grapher.list_wh_nagios_labels(?) AS l
                JOIN wh_nagios.list_services() AS s
                    ON l.id_service = s.id
            });

        if (
            !defined $sth->execute($id) )
        {
            $self->render_exception( $dbh->errstr );
            $sth->finish;
            $dbh->rollback;
            $dbh->disconnect;
            return;
        }

        my @labels;

        my $row;

        while ( defined($row = $sth->fetchrow_hashref) ) {
            $row->{'unit'} = 'no unit' if $row->{'unit'} eq '';
            push @labels, { %{ $row } };
            $self->req->params->append( "labels", $row->{'id_label'}) if $row->{'checked'};
        }

        $sth->finish;

        # Prepare properties
        my $json = Mojo::JSON->new;
        my $config = $json->decode( $graph->{config} );
        delete $graph->{config};

        # Send each configuration value to prefill form
        foreach my $p ( keys %$config ) {
            $self->param( $p, $config->{$p} );
        }


        # Prefill the rest
        foreach my $p ( keys %$graph ) {
            $self->param( $p, $graph->{$p} );
        }

        # Is the graph associated with a service ?
        $self->stash(
            'id_server' => $id_server,
            'labels'    => \@labels,
            'graph'     => $graph->{'graph'}
        );
    }

    $dbh->disconnect;

    $self->render;
}

sub remove {
    my $self      = shift;
    my $id        = $self->param('id');
    my $dbh       = $self->database;
    my $id_server = $self->flash('id_server');
    my $sth;

    unless ($id_server) {

        # Get the graph, and the service if a service is associated
        $sth = $dbh->prepare(qq{
            SELECT id_server
            FROM pr_grapher.list_wh_nagios_graphs()
            WHERE id = ?
        });

        unless ( defined $sth->execute($id) ) {
            $self->render_exception( $dbh->errstr );
            $sth->finish;
            $dbh->rollback;
            $dbh->disconnect;
            return;
        }

        $id_server = $sth->fetchrow();

        $sth->finish;
    }

    # Get the graph, and the service if a service is associated
    $sth = $dbh->prepare(qq{
        DELETE FROM pr_grapher.graphs
        WHERE id = ?
    });

    unless ( defined $sth->execute($id) ) {
        $self->render_exception( $dbh->errstr );
        $sth->finish;
        $dbh->rollback;
        $dbh->disconnect;
        return;
    }
    $sth->finish;
    $dbh->disconnect;

    $self->msg->info("Graph deleted.");

    if ( (defined $self->flash('saved_route')) && (defined $self->flash('stack')) ) {
        return $self->redirect_to($self->flash('saved_route'), $self->flash('stack'));
    }

    return $self->redirect_to( 'server_host', id => $id_server );
}

sub clone {
    my $self      = shift;
    my $id        = $self->param('id');
    my $dbh       = $self->database;
    my $new_id;

    # Clone the graph and its associated labels
    my $sth = $dbh->prepare(qq{WITH graph AS (
            INSERT INTO pr_grapher.graphs
                (graph, description, y1_query, y2_query, config)
            SELECT 'Clone - ' || graph, description, y1_query,
                y2_query, config
            FROM pr_grapher.graphs
            WHERE id = ? returning id
        )
        INSERT INTO pr_grapher.graph_wh_nagios
        SELECT graph.id, id_label
        FROM pr_grapher.graph_wh_nagios, graph
        WHERE id_graph=?
        RETURNING id_graph
    });

    unless ( defined $sth->execute( $id, $id ) ) {
        $self->render_exception( $dbh->errstr );
        $sth->finish;
        $dbh->rollback;
        $dbh->disconnect;
        return;
    }

    ( $new_id ) = $sth->fetchrow;
    $sth->finish;
    $dbh->disconnect;

    $self->msg->info("Graph cloned, please edit it.");

    return $self->redirect_to( 'graphs_edit', id => $new_id );
}

sub data {
    my $self = shift;

    my $y1_query   = $self->param('y1_query');
    my $y2_query   = $self->param('y2_query');
    my $id         = $self->param('id');
    my $from       = $self->param("from");
    my $to         = $self->param("to");
    my $config;
    my $isservice = 0;
    my $data      = [];
    my $json      = Mojo::JSON->new;

    # Double check the input
    if ( !defined $y1_query && !defined $y2_query && !defined $id ) {
        return $self->render( 'json' => { error => "post: Bad input" } );
    }

    my $dbh = $self->database;
    my $sth;

    # When a graph id is received, retrieve the queries and the properties from the DB
    if ( defined $id ) {
        $sth = $dbh->prepare(
            qq{SELECT y1_query, y2_query, config FROM pr_grapher.list_graph() WHERE id = ?}
        );
        $sth->execute($id);

        ( $y1_query, $y2_query, $config ) = $sth->fetchrow;
        $sth->finish;

        if ( defined $config ) {
            my $json = Mojo::JSON->new;
            $config = $json->decode($config);
        }

        #Is the graph linked to a service ?
        $sth = $dbh->prepare(
            "SELECT id_service IS NOT NULL FROM pr_grapher.list_wh_nagios_graphs() WHERE id = ?"
        );
        $sth->execute($id);
        $isservice = $sth->fetchrow;
        $sth->finish;
    }

    if ( not $isservice ) { # Regular graph
        if ( defined $y1_query and $y1_query !~ m!^\s*$! ) {
            my $series = {};

            $sth = $dbh->prepare($y1_query);
            if ( !defined $sth->execute ) {
                my $error = { error => '<pre>' . $dbh->errstr . '</pre>' };
                $sth->finish;
                $dbh->rollback;
                $dbh->disconnect;
                return $self->render( 'json' => $error );
            }

            # Use the NAME attribute of the statement handle to have the order
            # of the columns. Since we are working with hashes to build the
            # series form the columns names, this let us output the right
            # order which is not garantied by walking keys of a hash.
            my @cols = @{ $sth->{NAME} };

            # The first columns is always the x value of the point.
            my $first_col = shift @cols;

            # Build the data struct for Flotr: a hash of series labels with
            # lists of points. Points are list of x,y values)
            while ( my $row = $sth->fetchrow_hashref ) {
                my $x = $row->{$first_col};
                foreach my $c (@cols) {
                    $series->{$c} = [] if !exists $series->{$c};
                    push @{ $series->{$c} }, [ $x, $row->{$c} ];
                }
            }
            $sth->finish;

            # Create the final struct: a list of hashes { data: [], label: "col" }
            foreach my $c (@cols) {
                push @{$data}, { data => $series->{$c}, label => $c };
            }
        }

        if ( defined $y2_query and $y2_query !~ m!^\s*$! ) {

            # Do the same for y2
            my $series = {};
            $sth = $dbh->prepare($y2_query);

            if ( !defined $sth->execute ) {
                my $error = { error => '<pre>' . $dbh->errstr . '</pre>' };
                $sth->finish;
                $dbh->rollback;
                $dbh->disconnect;
                return $self->render( 'json' => $error );
            }

            my @cols      = @{ $sth->{NAME} };
            my $first_col = shift @cols;
            while ( my $row = $sth->fetchrow_hashref ) {
                my $x = $row->{$first_col};
                foreach my $c (@cols) {
                    $series->{$c} = [] if !exists $series->{$c};
                    push @{ $series->{$c} }, [ $x, $row->{$c} ];
                }
            }
            $sth->finish;

            # Create the final struct: a list of hashes { data: [], label: "col", yaxis : 2 }
            foreach my $c (@cols) {
                push @{$data}, { data => $series->{$c}, label => $c };
            }
        }
    }
    else {# Graph is linked to a service
        $sth = $dbh->prepare(
            qq{SELECT s.hostname || '::' || graph AS graph,description
            FROM pr_grapher.list_wh_nagios_graphs() g
            JOIN public.list_servers() s ON s.id = g.id_server
            WHERE g.id = ?});
        $sth->execute($id);
        my ($graphtitle,$graphsubtitle) = $sth->fetchrow();
        $sth->finish();
        $config->{'title'} = $graphtitle;
        $config->{'subtitle'} = $graphsubtitle;

        $sth = $dbh->prepare(qq{
            SELECT id_label, label, unit
            FROM pr_grapher.list_wh_nagios_labels(?)
            WHERE available;
        });
        $sth->execute($id);

        my $series = {};
        my $sql;
        $from = substr $from, 0, -3;
        $to = substr $to, 0, -3;

        #FIXME: handle wh_nagios as a module
        $sql = $dbh->prepare(
            "SELECT pr_grapher.js_time(timet), value FROM wh_nagios.get_sampled_label_data(?, to_timestamp(?), to_timestamp(?), ?);"
        );

        while ( my ( $id_label, $label, $unit ) = $sth->fetchrow() ) {
            $sql->execute( $id_label, $from, $to,
                sprintf( "%.0f", ( $to - $from ) / 700 ) );
            $series->{$label} = [];
            while ( my ( $x, $y ) = $sql->fetchrow() ) {
                push @{ $series->{$label} }, [ 0 + $x, ($y eq "NaN" ? undef : 0.0 + $y ) ];
            }
            $sql->finish;
            push @{$data}, { data => $series->{$label}, label => $label };

            # Buggy with multiple units!
            $config->{'yaxis_unit'} = $unit;
        }
        $config->{'yaxis_autoscale'} = $json->true;
        $config->{'yaxis_autoscaleMargin'} = 0.2;

        $sth->finish;

        $dbh->disconnect;

        if ( !scalar(@$data) ) {
            return $self->render( 'json' => { error => "Empty output" } );
        }
    }

    return $self->render(
        'json' => {
            series     => $data,
            properties => $self->properties->to_plot($config)
        } );
}

1;

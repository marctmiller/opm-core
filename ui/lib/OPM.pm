package OPM;
use Mojo::Base 'Mojolicious';
use File::Spec::Functions qw(splitdir catdir);

# This program is open source, licensed under the PostgreSQL License.
# For license terms, see the LICENSE file.
#
# Copyright (C) 2012-2014: Open PostgreSQL Monitoring Development Group

use vars qw($VERSION);
$VERSION = '2.0.0_1';

has opm_plugins => sub { my %plugins; return \%plugins; };

# This method will run once at server start
sub startup {
    my $self = shift;

    # load configuration
    my $config_file = $self->home . '/opm.conf';
    my $config = $self->plugin( 'JSONConfig' => { file => $config_file } );

    # setup secret passphrase
    if ( $config->{secrets} ) {
        $self->secrets( $config->{secrets} );
    }
    $self->register_routes();
    $self->register_plugins();

    # CGI pretty URLs
    if ( $config->{rewrite} ) {
        $self->hook(
            before_dispatch => sub {
                my $self = shift;
                $self->req->url->base(
                    Mojo::URL->new( $config->{base_url} ) );
            } );
    }
}

# This method is responsible for registering all the plugins, both "core"
# Mojolicious plugins, and OPM plugins
sub register_plugins {
    my $self = shift;

    # register Helpers plugins namespace
    $self->plugins->namespaces(
        [ "Helpers", "OPM", @{ $self->plugins->namespaces } ] );

    # setup charset
    $self->plugin( charset => { charset => 'utf8' } );
    $self->plugin(
        I18N => {
            namespace         => 'OPM::I18N',
            support_url_langs => [qw(en fr)]
        } );
    $self->plugin( 'database', $self->config->{database} || {} );

    # Load HTML Messaging plugin
    $self->plugin('messages');

    # Load others "core" plugins
    $self->plugin('menu');
    $self->plugin('permissions');
    $self->plugin('utils');

    # Load OPM-plugins
    foreach my $plugin ( @{ $self->config->{'plugins'} } ) {
        $self->opm_plugin($plugin);
    }
}

# Register an OPM plugin.
sub opm_plugin {
    my ( $self, $plugin ) = @_;
    my $opm_plugin_instance;
    my $route_base = $self->routes->route("/$plugin");
    my $registry   = $self->opm_plugins;
    push( @INC,
        catdir( splitdir( $self->home ), 'modules', $plugin, 'lib' ) );
    $opm_plugin_instance = $self->plugin( $plugin,
        home => catdir( splitdir( $self->home ), 'modules', $plugin ) );
    $opm_plugin_instance->register_routes(
        $route_base,
        $route_base->bridge->to('users#check_auth'),
        $route_base->bridge->to('users#check_admin') );
    $registry->{$plugin} = $opm_plugin_instance;
}

# TODO: think about moving the routes declaration elsewhere when this get too
# big
#
# This method is responsible for registering all main application routes
sub register_routes {
    my $self   = shift;
    my $r      = $self->routes;
    my $r_auth = $r->bridge->to('users#check_auth');
    my $r_adm  = $r_auth->bridge->to('users#check_admin');

    # Home page
    $r_auth->route('/')->to('server#list')->name('site_home');
    $r_auth->route('/about')->to('users#about')->name('site_about');

    # Lang
    $r->route('/lang/:code')->to('lang#set')->name('lang_set');

    # User stuff
    $r->route('/login')->to('users#login')->name('users_login');
    $r_auth->route('/profile')->to('users#profile')->name('users_profile');

    $r_auth->route('/change_password')->to('users#change_password')
        ->name('users_change_password');
    $r_auth->route('/logout')->to('users#logout')->name('users_logout');
    if ( $self->config->{allow_register} ) {
        $r->route('/register')->to('users#register')->name('users_register');
    }

    # User management
    $r_adm->route('/users')->to('users#list')->name('users_list');
    $r_adm->route('/users/create')->to('users#create')->name('users_create');
    $r_adm->route('/users/:rolname')->to('users#edit')->name('users_edit');
    $r_adm->route('/users/delete/:rolname')->to('users#delete')
        ->name('users_delete');
    $r_adm->route('/users/delacc/:accname/:rolname')->to('users#delacc')
        ->name('users_delacc');

    # Account management
    $r_adm->route('/accounts/')->to('accounts#adm')->name('accounts_adm');
    $r_adm->route('/accounts/create')->to('accounts#create')
        ->name('accounts_create');
    $r->route('/accounts/:accname/')->to('accounts#list')
        ->name('accounts_list');
    $r_adm->route('/accounts/:accname/edit')->to('accounts#edit')
        ->name('accounts_edit');
    $r_adm->route('/accounts/:accname/add_user')->to('accounts#add_user')
        ->name('accounts_add_user');
    $r_adm->route('/accounts/:accname/add_server')->to('accounts#add_server')
        ->name('accounts_add_server');
    $r_adm->route('/accounts/:accname/new_user')->to('accounts#new_user')
        ->name('accounts_new_user');

    $r_adm->route('/accounts/delete/:accname')->to('accounts#delete')
        ->name('accounts_delete');
    $r_adm->route('/accounts/delrol/:accname/:rolname')
        ->to('accounts#delrol')->name('accounts_delrol');
    $r_adm->route('/accounts/revokeserver/:accname/:idserver')
        ->to('accounts#revokeserver')->name('accounts_revokeserver');

    # Server management
    $r_auth->route('/server')->to('server#list')->name('server_list');
    $r_auth->route( '/server/:id', id => qr/\d+/ )->to('server#host')
        ->name('server_host');
    $r_auth->route('/server/:server')->to('server#host_by_name')
        ->name('server_host_by_name');

    # Search bar
    $r_auth->route('/search/server')->to('search#server')
        ->name('search_server');

}

return 1;

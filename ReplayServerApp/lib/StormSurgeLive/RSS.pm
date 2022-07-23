package StormSurgeLive::RSS;

use strict;
use warnings;

use XML::RSS ();

{
    no warnings qw/redefine/;

    # monkey patch this method to control attributes in the <rss..> tag
    *XML::RSS::_get_default_modules = sub {
        return { 'http://purl.org/dc/elements/1.1/' => 'dc', };
    };

    *XML::RSS::Private::Output::Base::_get_rdf_decl_open_tag = sub {
        return qq{<rss version="2.0" };
    };

    *XML::RSS::Private::Output::Base::_render_xmlns = sub {
        my ( $self, $prefix, $url ) = @_;
        my $pp = defined($prefix) ? ":$prefix" : "";
        return qq{ xmlns$pp="$url"};
    };

    *XML::RSS::Private::Output::Base::_get_rdf_decl = sub {
        my $self      = shift;
        my $base      = $self->_main()->{'xml:base'};
        my $base_decl = ( defined $base ) ? qq{ xml:base="$base"\n} : "";
        return $self->_get_rdf_decl_open_tag() . $base_decl . $self->_get_rdf_xmlnses() . ">\n";
    };

    *XML::RSS::Private::Output::Base::_output_xml_declaration = sub {
        my $self = shift;
        my $encoding =
          ( defined $self->_main->_encoding() ) ? ' encoding="' . $self->_main->_encoding() . '"' : "";
        $self->_out( '<?xml version="1.0"' . $encoding . '?>' . "\n" );
        if ( defined( my $stylesheet = $self->_main->_stylesheet ) ) {
            my $style_url = $self->_encode($stylesheet);
            $self->_out(qq{<?xml-stylesheet type="text/xsl" href="$style_url"?>\n});
        }
        return undef;
    };

}

1;

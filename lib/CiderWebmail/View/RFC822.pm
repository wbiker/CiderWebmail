package CiderWebmail::View::RFC822;
use Moose;
use namespace::autoclean;

use Encode;

use Email::Sender::Simple qw/sendmail/;
use Email::Sender::Transport::Sendmail;
use Email::Sender::Transport::SMTP;

extends 'Catalyst::View';

=head1 NAME

CiderWebmail::View::RFC822 - Catalyst View for sending e-Mail

=cut

=head1 DESCRIPTION

This Catalyst View sends out a Message as specified on the stash in the email key.

=cut

sub process {
    my ($self, $c) = @_;

    #this is the top-level message we are going to send
    my $mail = MIME::Entity->build(
        Type        => 'multipart/mixed',
        From        => $c->stash->{email}->{from},
        To          => $c->stash->{email}->{to},
        Date        => DateTime::Format::Mail->new->format_datetime(DateTime->now),
        ($c->stash->{email}->{cc} ? (Cc => $c->stash->{email}->{cc}) : ()),
        Subject     => Encode::encode('MIME-Header', $c->stash->{email}->{subject}),
        'X-Mailer'  => "CiderWebmail ".$CiderWebmail::VERSION,
        Received    => "from " .  ( defined $c->req->address ? $c->req->address : 'unknown REMOTE_ADDR' ) . 
                       ( $c->req->address ne $c->req->hostname ? ' [' . $c->req->hostname . ']' : '' ) . #insert hostname of the client if provided by the webserver
                       " by " .   ( defined $c->req->uri->host ? $c->req->uri->host : 'unknown SERVER_NAME' ) . 
                       " with " . ( $c->req->secure ? 'HTTPS' : 'HTTP' ) . "; " .
                       DateTime::Format::Mail->new->format_datetime(DateTime->now),
    );

    #this is our main body - the text the user specified
    if ($c->stash->{email}->{body}) { #TODO decent check if we have a valid body? what if only forwarding as attachment etc?
        utf8::encode($c->stash->{email}->{body});
        my $body_entity = MIME::Entity->build(
            Type    => 'text/plain',
            Charset => 'UTF-8',
            Data    => $c->stash->{email}->{body},
        );

        $mail->add_part($body_entity);
    }

    if (my @attachments = $c->req->param('attachment')) {
        foreach ($c->req->upload('attachment')) {
            $mail->attach(
                Type        => $_->type,
                Filename    => $_->basename,
                Path        => $_->tempname,
                Disposition => 'attachment',
                ReadNow     => 1,
            );
        }
    }

    if (defined $c->req->param('forward')) {
        my ($uid, $part_id) = CiderWebmail::Util::parse_message_id($c->req->param('forward'));
        my $part_to_forward = CiderWebmail::Message->new(c => $c, mailbox => $c->stash->{folder}, uid => $uid)->get_part_by_part_id({ part_id => $part_id });

        $mail->attach(
            Type     => 'message/rfc822',
            Filename => $part_to_forward->subject . '.eml',
            Data     => $part_to_forward->body,
        );
    }

    if (defined $c->req->param('in_reply_to')) {
        my ($uid, $part_id) = CiderWebmail::Util::parse_message_id($c->req->param('in_reply_to'));
        my $in_reply_to_part = CiderWebmail::Message->new(c => $c, mailbox => $c->stash->{folder}, uid => $uid)->get_part_by_part_id({ part_id => $part_id });

        if ($in_reply_to_part) {
            if (my $message_id = $in_reply_to_part->message_id) {
                $mail->add('In-Reply-To', $message_id);
                my $references = $in_reply_to_part->references;
                $mail->add('References', join ' ', $references ? split /\s+/sxm, $references : (), $message_id);
            }

            $in_reply_to_part->mark_answered;
        } 
    }

    if (defined($c->stash->{'email'}->{'signature'}) and (length($c->stash->{'email'}->{'signature'}) > 0)) {
        $mail->sign(Signature => $c->stash->{'email'}->{'signature'});
    }
    
    #deliver mail
    my $transport;

    #TODO add port and example to ciderwebmail.yml
    if (($c->config->{send}->{method} or '') eq 'smtp') {
        croak('smtp host not set') unless defined $c->config->{send}->{host};

        $transport = Email::Sender::Transport::SMTP->new({
            host => $c->config->{send}->{host},
            port => '25',
        });
    } else {
        $transport = Email::Sender::Transport::Sendmail->new();
    }

    if (defined $c->stash->{email}->{save_to_folder}) {
        my $msg_text = $mail->as_string;
        $c->model('IMAPClient')->append_message({mailbox => $c->stash->{email}->{save_to_folder}, message_text => $msg_text});
    }

    sendmail($mail, { transport => $transport });
}

=head1 AUTHOR

Mathias Reitinger <mathias.reitinger@loop0.org>

=head1 LICENSE

This library is free software. You can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

__PACKAGE__->meta->make_immutable;

1;

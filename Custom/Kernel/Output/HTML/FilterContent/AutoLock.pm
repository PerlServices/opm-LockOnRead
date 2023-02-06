# --
# Copyright (C) 2016 - 2023 Perl-Services.de, https://www.perl-services.de/
# --
# This software comes with ABSOLUTELY NO WARRANTY. For details, see
# the enclosed file COPYING for license information (AGPL). If you
# did not receive this file, see http://www.gnu.org/licenses/agpl.txt.
# --

package Kernel::Output::HTML::FilterContent::AutoLock;

use strict;
use warnings;

sub new {
    my ( $Type, %Param ) = @_;

    # allocate new hash for object
    my $Self = {};
    bless( $Self, $Type );

    $Self->{UserID} = $Param{UserID};

    return $Self;
}

sub Run {
    my ( $Self, %Param ) = @_;

    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');
    my $ParamObject  = $Kernel::OM->Get('Kernel::System::Web::Request');
    my $TicketObject = $Kernel::OM->Get('Kernel::System::Ticket');
    my $LayoutObject = $Kernel::OM->Get('Kernel::Output::HTML::Layout');
    my $LogObject    = $Kernel::OM->Get('Kernel::System::Log');
    my $UserObject   = $Kernel::OM->Get('Kernel::System::User');

    my $Action = $ParamObject->GetParam( Param => 'Action' );

    return 1 if !$Action;
    return 1 if !$Param{Templates}->{$Action};
    
    my $TicketID = $ParamObject->GetParam( Param => 'TicketID' );
    my $UserID   = $Self->{UserID} // $LayoutObject->{UserID};

    return 1 if !$TicketID;
    return 1 if !$UserID;

    my %Ticket = $TicketObject->TicketGet(
        TicketID => $TicketID,
        UserID   => $UserID,
    );

    # if ticket is already locked, this module should skip the lock action
    # to avoid a lock/owner ping pong
    return 1 if !%Ticket;
    return 1 if $Ticket{Lock} eq 'lock';

    # do not set the owner to the current user when he/she has no rw
    # permissions on the ticket. users without rw permissions can do nothing
    # useful with the ticket
    my $Access = $TicketObject->TicketPermission(
        Type     => 'rw',
        TicketID => $TicketID,
        UserID   => $UserID,
    );

    return 1 if !$Access;

    # queue check
    my $Queues     = $ConfigObject->Get('LockOnRead::Queues') || [];
    my %OnlyQueues = map { $_ => 1 } @{ $Queues || [] };

    return 1 if %OnlyQueues && !$OnlyQueues{ $Ticket{Queue} };

    # check if update is needed!
    my ( $OwnerID, $Owner ) = $TicketObject->OwnerCheck( TicketID => $TicketID );
    if ( $OwnerID ne $UserID ) {

        # db update
        return if !$Kernel::OM->Get('Kernel::System::DB')->Do(
            SQL => 'UPDATE ticket SET user_id = ? WHERE id = ?',
            Bind => [ \$UserID, \$TicketID ],
        );

        my $NewUser = $UserObject->UserLookup(
            UserID => $UserID,
        );

        $TicketObject->HistoryAdd(
            TicketID     => $TicketID,
            CreateUserID => $UserID,
            HistoryType  => 'OwnerUpdate',
            Name         => "\%\%$NewUser\%\%$UserID",
        );
    }


    my $LockID = $Kernel::OM->Get('Kernel::System::Lock')->LockLookup(
        Lock => 'lock',
    );

    # lock ticket
    return if !$Kernel::OM->Get('Kernel::System::DB')->Do(
        SQL => 'UPDATE ticket SET ticket_lock_id = ? WHERE id = ?',
        Bind => [ \$LockID, \$TicketID ],
    );

    $TicketObject->HistoryAdd(
        TicketID     => $TicketID,
        CreateUserID => $UserID,
        HistoryType  => 'Lock',
        Name         => "\%\%lock",
    );


    # clear ticket cache
    $TicketObject->_TicketCacheClear( TicketID => $TicketID );

    # replace "unlocked" info in ticketinformation
    my $Label  = $LayoutObject->{LanguageObject}->Translate("Locked");
    my $Locked = $LayoutObject->{LanguageObject}->Translate("lock");
    ${ $Param{Data} } =~ s{
        <label> $Label: </label> \s+
        <p \s* class="Value" \s* \K
        .*? </p>
    }{
        title="$Locked">$Locked </p>
    }xms;

    # replace Link
    my $LinkText = $LayoutObject->{LanguageObject}->Translate("Unlock");
    ${ $Param{Data} } =~ s{
        Subaction=Lock(.*?)>.*?</a>
    }{Subaction=Unlock$1>$LinkText</a>}xms;

    return 1;
}

1;


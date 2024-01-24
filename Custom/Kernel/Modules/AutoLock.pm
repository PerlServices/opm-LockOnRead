# --
# Copyright (C) 2016 - 2023 Perl-Services.de, https://www.perl-services.de/
# --
# This software comes with ABSOLUTELY NO WARRANTY. For details, see
# the enclosed file COPYING for license information (AGPL). If you
# did not receive this file, see http://www.gnu.org/licenses/agpl.txt.
# --

package Kernel::Modules::AutoLock;

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

sub PreRun {
    my ( $Self, %Param ) = @_;

    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');
    my $ParamObject  = $Kernel::OM->Get('Kernel::System::Web::Request');
    my $TicketObject = $Kernel::OM->Get('Kernel::System::Ticket');
    my $LayoutObject = $Kernel::OM->Get('Kernel::Output::HTML::Layout');
    my $LogObject    = $Kernel::OM->Get('Kernel::System::Log');
    my $UserObject   = $Kernel::OM->Get('Kernel::System::User');

    my $Action = $ParamObject->GetParam( Param => 'Action' );

    return if !$Action;
    
    my $TicketID = $ParamObject->GetParam( Param => 'TicketID' );
    my $UserID   = $Self->{UserID} // $LayoutObject->{UserID};

    return if !$TicketID;
    return if !$UserID;

    my %Ticket = $TicketObject->TicketGet(
        TicketID => $TicketID,
        UserID   => $UserID,
    );

    # if ticket is already locked, this module should skip the lock action
    # to avoid a lock/owner ping pong
    return if !%Ticket;
    return if $Ticket{Lock} eq 'lock';

    # do not set the owner to the current user when he/she has no rw
    # permissions on the ticket. users without rw permissions can do nothing
    # useful with the ticket
    my $Access = $TicketObject->TicketPermission(
        Type     => 'rw',
        TicketID => $TicketID,
        UserID   => $UserID,
    );

    return if !$Access;

    # queue check
    my $Queues     = $ConfigObject->Get('LockOnRead::Queues') || [];
    my %OnlyQueues = map { $_ => 1 } @{ $Queues || [] };

    return if %OnlyQueues && !$OnlyQueues{ $Ticket{Queue} };

    # state check
    my $States     = $ConfigObject->Get('LockOnRead::States') || [];
    my %OnlyStates = map { $_ => 1 } @{ $States || [] };

    return if %OnlyStates && !$OnlyStates{ $Ticket{State} };

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


    $TicketObject->TicketLockSet(
        Lock     => 'lock',
        UserID   => $UserID,
        TicketID => $TicketID,
    );

    $TicketObject->EventHandlerTransaction();

    return $LayoutObject->Redirect( OP => "Action=AgentTicketZoom&TicketID=$TicketID" );
}

1;


# --
# Copyright (C) 2018 - 2023 Perl-Services.de, https://perl-services.de
# --
# This software comes with ABSOLUTELY NO WARRANTY. For details, see
# the enclosed file COPYING for license information (AGPL). If you
# did not receive this file, see http://www.gnu.org/licenses/agpl.txt.
# --

package Kernel::System::Ticket::Custom::LockOnRead;

use strict;
use warnings;

our $ObjectManagerDisabled = 1;

# disable redefine warnings in this scope
{
    no warnings 'redefine';
    sub Kernel::System::Ticket::TicketLockSet {
        my ( $Self, %Param ) = @_;

        # lookup!
        if ( !$Param{LockID} && $Param{Lock} ) {

            $Param{LockID} = $Kernel::OM->Get('Kernel::System::Lock')->LockLookup(
                Lock => $Param{Lock},
            );
        }
        if ( $Param{LockID} && !$Param{Lock} ) {

            $Param{Lock} = $Kernel::OM->Get('Kernel::System::Lock')->LockLookup(
                LockID => $Param{LockID},
            );
        }

        # check needed stuff
        for my $Needed (qw(TicketID UserID LockID Lock)) {
            if ( !$Param{$Needed} ) {
                $Kernel::OM->Get('Kernel::System::Log')->Log(
                    Priority => 'error',
                    Message  => "Need $Needed!"
                );
                return;
            }
        }
        if ( !$Param{Lock} && !$Param{LockID} ) {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => 'Need LockID or Lock!'
            );
            return;
        }

        # check if update is needed
        my %Ticket = $Self->TicketGet(
            %Param,
            DynamicFields => 0,
        );
        return 1 if $Ticket{Lock} eq $Param{Lock};

        # db update
        return if !$Kernel::OM->Get('Kernel::System::DB')->Do(
# ---
# PS
# ---
#            SQL => 'UPDATE ticket SET ticket_lock_id = ?, '
#                . ' change_time = current_timestamp, change_by = ? WHERE id = ?',
#            Bind => [ \$Param{LockID}, \$Param{UserID}, \$Param{TicketID} ],
            SQL => 'UPDATE ticket SET ticket_lock_id = ? '
                . ' WHERE id = ?',
            Bind => [ \$Param{LockID}, \$Param{TicketID} ],
# ---
        );

        # clear ticket cache
        $Self->_TicketCacheClear( TicketID => $Param{TicketID} );

        # add history
        my $HistoryType = '';
        if ( lc $Param{Lock} eq 'unlock' ) {
            $HistoryType = 'Unlock';
        }
        elsif ( lc $Param{Lock} eq 'lock' ) {
            $HistoryType = 'Lock';
        }
        else {
            $HistoryType = 'Misc';
        }
        if ($HistoryType) {
            $Self->HistoryAdd(
                TicketID     => $Param{TicketID},
                CreateUserID => $Param{UserID},
                HistoryType  => $HistoryType,
                Name         => "\%\%$Param{Lock}",
            );
        }

        # set unlock time it event is 'lock'
        if ( $Param{Lock} eq 'lock' ) {

            # create datetime object
            my $DateTimeObject = $Kernel::OM->Create('Kernel::System::DateTime');

            $Self->TicketUnlockTimeoutUpdate(
                UnlockTimeout => $DateTimeObject->ToEpoch(),
                TicketID      => $Param{TicketID},
                UserID        => $Param{UserID},
            );
        }

        # send unlock notify
        if ( lc $Param{Lock} eq 'unlock' ) {

            my $Notification = defined $Param{Notification} ? $Param{Notification} : 1;
            if ( !$Param{SendNoNotification} && $Notification )
            {
                my @SkipRecipients;
                if ( $Ticket{OwnerID} eq $Param{UserID} ) {
                    @SkipRecipients = [ $Param{UserID} ];
                }

                # trigger notification event
                $Self->EventHandler(
                    Event          => 'NotificationLockTimeout',
                    SkipRecipients => \@SkipRecipients,
                    Data           => {
                        TicketID              => $Param{TicketID},
                        CustomerMessageParams => {},
                    },
                    UserID => $Param{UserID},
                );
            }
        }

        # trigger event
        $Self->EventHandler(
            Event => 'TicketLockUpdate',
            Data  => {
                TicketID => $Param{TicketID},
            },
            UserID => $Param{UserID},
        );

        return 1;
    }

}

1;

=head1 TERMS AND CONDITIONS

This software comes with ABSOLUTELY NO WARRANTY. For details, see
the enclosed file COPYING for license information (AGPL). If you
did not receive this file, see L<http://www.gnu.org/licenses/agpl.txt>.

=cut

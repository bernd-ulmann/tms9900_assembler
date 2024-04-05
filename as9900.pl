#
# as9900.pl - a simple cross assembler for TMS9900-microprocessors, written by B. Ulmann.
#
# 03-NOV-2013:  Start of implementation, main pass-structure implemented, no constructors yet (5h)
# 04-NOV-2013:  Implementation of constructors (6h)
# 05-NOV-2013:  Partial reimplementation of get_operand() and other basic functions etc. (3h)
# 06-NOV-2013:  Implemented simple .EQUs, reimplemented XOP, implemented remaining instruction formats (4h)
# 18-NOV-2013:  Added -im qualifier to generate output that can be pasted into an EVMBUG terminal session (2h)
#               Added .BSS
#               .TEXT now understands "\n"
# 20-NOV-2013:  Fixed a bug which caused register-indirect-addressing to be recognized as register-direct. (5m)
#

use strict;
use warnings;

use Data::Dumper;
use Getopt::Long;

sub list_labels
{
    my ($labels, $label_length) = @_;
    print '-' x 79, "\n", scalar(keys(%$labels)), " labels, sorted by name:\n";
    my $column;
    for my $name (sort(keys(%{$labels})))
    {
        $labels->{$name} = 0 unless defined($labels->{$name}); #TODO: Beware of side effect!!! Can this even occur?
        printf("%-${label_length}s: %04X    %s", $name, $labels->{$name}, ++$column %3 ? '' : "\n");
    }
    print "\n" if $column % 3;
    print '-' x 79, "\n", scalar(keys(%$labels)), " labels, sorted by address:\n";

    $column = 0;
    printf("%-${label_length}s: %04X    %s", $_, $labels->{$_}, ++$column % 3 ? '' : "\n")
        for (sort{$labels->{$a} <=> $labels->{$b}}(keys(%{$labels})));
    print "\n" if $column % 3;
    print '-' x 79, "\n";
}

sub list_program
{
    my ($program, $label_length) = @_;
    for my $line (@$program)
    {
        my $string;
        # Print the current address:
        $string .= defined($line->{address}) ? sprintf("%04X ", $line->{address}) : '     ';

        # Print the memory contents:
        my ($counter, $nl_flag) = (0, 0);
        for my $value (@{$line->{data}})
        {
            ($string .= "\n     ") and ($nl_flag = 0) if $nl_flag;
            $string .= sprintf("%04X ", $value);
            $nl_flag = 1 unless ++$counter % 3;
        }

        # Fill with blanks as needed (for 0, 1, 2 and more operands with a maximum of 3 operands per line):
        my $fill = 3 - $counter % 3;
        $fill %= 3 if $counter;
        $string .= '     ' x $fill;

        # Print label, instruction, parameters and comment:
        $string .= $line->{label}      ? sprintf("%-${label_length}s", $line->{label}) : ' ' x $label_length;
        $string .= $line->{operation}  ? sprintf("%-6s", $line->{operation}) : '      ';
        $string .= $line->{parameters} ? sprintf("%-20s", join(', ', @{$line->{parameters}})) : ' ' x 20;
        $string .= $line->{comment} if $line->{comment};
        $string .= join("\n\tERROR:\t", ('', @{$line->{errors}})) if @{$line->{errors}} > 0;

        print "$string\n";
    }
}

sub generate_im
{
    my ($program) = @_;
    my ($start_address, $output);
    for my $line (@$program)
    {
        next unless defined($line->{address}); # Nothing to do if there is no address at all.
        $output .= sprintf("IM %04X ", $start_address = $line->{address}) unless $start_address;

        $output .= sprintf("%04X ", $_) for @{$line->{data}};
    }
    $output .= sprintf("\nIR  %04X \nEX ", $start_address);
    print "Paste this:\n\n$output\n";
}

my %addressing_modes = (
    'register direct'                 => { t => 0, constants => 0 },
    'register indirect'               => { t => 1, constants => 0 },
    'register indirect autoincrement' => { t => 3, constants => 0 },
    'symbolic indexed'                => { t => 2, constants => 1 },
    'symbolic'                        => { t => 2, constants => 1 },
);

sub get_addressing_mode
{
    my ($parameter, $labels) = @_;
    return 'symbolic'                        if defined($labels->{$parameter});
    return 'register direct'                 if uc($parameter) =~ /^R\d+$/;
    return 'register indirect'               if uc($parameter) =~ /^[\*@]R\d+$/;
    return 'register indirect autoincrement' if uc($parameter) =~ /^[\*@]R\d+\+$/;
    return 'symbolic indexed'                if uc($parameter) =~ /^[\*@]?[>\$][0-9A-F]+\(R\d+\)$/;
    return 'symbolic'                        if uc($parameter) =~ /^[\*@]?[>\$][0-9A-F]+$/ or uc($parameter) =~ /^[\*@]?\d+$/;
    
    my ($possible_label) = $parameter =~ /^[\*@]?(\w+)?$/;
    return 'symbolic' if defined($possible_label) and $labels->{$possible_label};
    
    ($possible_label) = $parameter =~ /^[\*@]?(\w+)(\([rR]\d+\))?$/;
    return 'symbolic indexed' if defined($possible_label) and $labels->{$possible_label};
    
    return; # Unknown addressing mode
}

sub get_value
{
    my ($string, $labels) = @_;

    return { value => hex($1) }            if uc($string) =~ /^[>\$]([0-9A-F]+)(\([Rr]\d+\))?$/; # Hex value
    return { value => $1 }                 if    $string  =~ /^(\d+)(\([Rr]\d+\))?/;             # Decimal value
    return { value => $labels->{$string} } if defined($labels->{$string});
    
    my ($possible_label) = $string =~ /^[\*@]?(\w+)(\([rR]\d+\))?$/;
    return { value => $labels->{$possible_label} } if $possible_label and defined($labels->{$possible_label});

    return { error => "Could not convert >>$string<<" };
}

sub get_operand
{
    my ($parameter, $labels) = @_;
    my %result = ( errors => [] );
    unless (my $mode = get_addressing_mode($parameter, $labels))
    {
        push(@{$result{errors}}, "Unknown addressing mode in >>$parameter<<!");
    }
    else
    {
        my $register = 0;
        my $t = $addressing_modes{$mode}{t}; # These are the two T-bits
        $result{mode} = $mode; # This makes error handling more easy in calling routines.
        if ($mode eq 'register direct' or $mode eq 'register indirect' or $mode eq 'register indirect autoincrement')
        {
            ($register) = uc($parameter) =~ /^[\*@]?R(\d+)\+?$/;
        }
        elsif ($mode eq 'symbolic' or $mode eq 'symbolic indexed')
        {
            my ($value) = $parameter =~ /^[\*@]?(.+)$/;
            my $retval = get_value($value, $labels);
            if ($retval->{error})
            {
                push(@{$result{errors}}, $retval->{error});
            }
            else
            {
                $result{constant} = $retval->{value} & 0xffff;
            }

            ($register) = uc($parameter) =~ /\(R(\d+)\)$/ if $mode eq 'symbolic indexed';
        }
        else
        {
            push(@{$result{errors}}, "Internal error in get_operand, unexpected mode >>$mode<< detected.");
        }
        $result{register} = $register & 0xf; # In some cases it is handy to have T and R in separate locations
        $result{t}        = $t & 0x3;        # instead of a combined value in operand.
        $result{operand} = (($t & 0x3) << 4) | ($register & 0xf);
    }
    return \%result;
}

my %instructions = (
    LI   => { format => 'immediate',        opcode => 0b000000100000 },
    AI   => { format => 'immediate',        opcode => 0b000000100010 },
    ANDI => { format => 'immediate',        opcode => 0b000000100100 },
    ORI  => { format => 'immediate',        opcode => 0b000000100110 },
    CI   => { format => 'immediate',        opcode => 0b000000101000 },

    LWPI => { format => 'immediate_noreg',  opcode => 0b000000101110 },
    LIMI => { format => 'immediate_noreg',  opcode => 0b000000110000 },

    STWP => { format => 'internal',         opcode => 0b000000101010 },
    LWP  => { format => 'internal',         opcode => 0b000000001001 },
    STST => { format => 'internal',         opcode => 0b000000101100 },
    LST  => { format => 'internal',         opcode => 0b000000001000 },

    IDLE => { format => 'control',          opcode => 0b00000011010 },
    RSET => { format => 'control',          opcode => 0b00000011011 },
    RTWP => { format => 'control',          opcode => 0b00000011100 },
    CKON => { format => 'control',          opcode => 0b00000011101 },
    CKOF => { format => 'control',          opcode => 0b00000011110 },
    LREX => { format => 'control',          opcode => 0b00000011111 },

    BLWP => { format => 'program',          opcode => 0b0000010000  },
    B    => { format => 'program',          opcode => 0b0000010001  },
    X    => { format => 'program',          opcode => 0b0000010010  },
    CLR  => { format => 'program',          opcode => 0b0000010011  },
    NEG  => { format => 'program',          opcode => 0b0000010100  },
    INV  => { format => 'program',          opcode => 0b0000010101  },
    INC  => { format => 'program',          opcode => 0b0000010110  },
    INCT => { format => 'program',          opcode => 0b0000010111  },
    DEC  => { format => 'program',          opcode => 0b0000011000  },
    DECT => { format => 'program',          opcode => 0b0000011001  },
    BL   => { format => 'program',          opcode => 0b0000011010  },
    SWPB => { format => 'program',          opcode => 0b0000011011  },
    SETO => { format => 'program',          opcode => 0b0000011100  },
    ABS  => { format => 'program',          opcode => 0b0000011101  },

    SRA  => { format => 'shift',            opcode => 0b00001000    },
    SRL  => { format => 'shift',            opcode => 0b00001001    },
    SLA  => { format => 'shift',            opcode => 0b00001010    },
    SRC  => { format => 'shift',            opcode => 0b00001011    },

    JMP  => { format => 'jump',             opcode => 0b00010000    },
    JLT  => { format => 'jump',             opcode => 0b00010001    },
    JLE  => { format => 'jump',             opcode => 0b00010010    },
    JEQ  => { format => 'jump',             opcode => 0b00010011    },
    JHE  => { format => 'jump',             opcode => 0b00010100    },
    JGT  => { format => 'jump',             opcode => 0b00010101    },
    JNE  => { format => 'jump',             opcode => 0b00010110    },
    JNC  => { format => 'jump',             opcode => 0b00010111    },
    JOC  => { format => 'jump',             opcode => 0b00011000    },
    JNO  => { format => 'jump',             opcode => 0b00011001    },
    JL   => { format => 'jump',             opcode => 0b00011010    },
    JH   => { format => 'jump',             opcode => 0b00011011    },
    JOP  => { format => 'jump',             opcode => 0b00011100    },
    SBO  => { format => 'jump',             opcode => 0b00011101    },
    SBZ  => { format => 'jump',             opcode => 0b00011110    },
    TB   => { format => 'jump',             opcode => 0b00011111    },

    COC  => { format => 'mpydiv',           opcode => 0b001000      },
    CZC  => { format => 'mpydiv',           opcode => 0b001001      },
    XOR  => { format => 'mpydiv',           opcode => 0b001010      },

    LDCR => { format => 'xopcru',           opcode => 0b001100      },
    STCR => { format => 'xopcru',           opcode => 0b001101      },
    XOP  => { format => 'xopcru',           opcode => 0b001011      },

    MPY  => { format => 'mpydiv',           opcode => 0b001110      },
    DIV  => { format => 'mpydiv',           opcode => 0b001111      },

    SZC  => { format => 'arithmetic',       opcode => 0b0100        },
    SZCB => { format => 'arithmetic',       opcode => 0b0101        },
    S    => { format => 'arithmetic',       opcode => 0b0110        },
    SB   => { format => 'arithmetic',       opcode => 0b0111        },
    C    => { format => 'arithmetic',       opcode => 0b1000        },
    CB   => { format => 'arithmetic',       opcode => 0b1001        },
    A    => { format => 'arithmetic',       opcode => 0b1010        },
    AB   => { format => 'arithmetic',       opcode => 0b1011        },
    MOV  => { format => 'arithmetic',       opcode => 0b1100        },
    MOVB => { format => 'arithmetic',       opcode => 0b1101        },
    SOC  => { format => 'arithmetic',       opcode => 0b1110        },
    SOCB => { format => 'arithmetic',       opcode => 0b1111        },

    '.ORG'  => { format => 'directive' },
    '.DATA' => { format => 'directive' },
    '.TEXT' => { format => 'directive' },
    '.EQU'  => { format => 'directive' },
    '.BSS'  => { format => 'directive' },
);

my $no_constants = sub
{
    my ($address) = @_; 
    return { my_address => $address, next_address => $address + 2, };  
};

my $maybe_one_constant = sub {
    my ($address, $parameters, $instruction, $labels) = @_;
    my %result = ( my_address => $address, errors => [] );
    my $addressing_mode = get_addressing_mode($parameters->[0], $labels);
    unless ($addressing_mode)
    {
        push(@{$result{errors}}, 'Could not determine addressing mode of source operand!');
    }
    else
    {
        $result{next_address} = $address + $addressing_modes{$addressing_mode}{constants} * 2 + 2;
    }
    return \%result;
};

my $one_constant = sub {
    my ($address) = @_;
    return { my_address => $address, next_address => $address + 4, };
};

# Dispatch table for the determination of instructions lengths in words (16 bits each):
my %instruction_lengths = (
    # Arithmetic instructions may have up to two constant parameters so they increment by 1, 2 or even 3:
    arithmetic => sub {
        my ($address, $parameters, $instruction, $labels) = @_;
        my %result = ( my_address => $address, errors => [] );
        unless (@$parameters == 2)
        {
            push(@{$result{errors}}, 'Two arguments were expected!');
        }
        else
        {
            my $increment = 2; # The PC points to the following (!) instruction, so we increment at least by 2 bytes.
            for my $parameter (@$parameters)
            {
                my $addressing_mode = get_addressing_mode($parameter, $labels);
                unless ($addressing_mode)
                {
                    push(@{$result{errors}}, 'Could not determine addressing mode!');
                }
                else
                {
                    $increment += $addressing_modes{$addressing_mode}{constants} * 2;
                }
            }
            $result{next_address} = $address + $increment;
        }
        return \%result;
    },

    #  Directives are nasty since some have no instrinsic length at all but can modify the address of
    # the following instruction (.ORG) etc. 
    directive => sub {
        my ($address, $parameters, $directive) = @_;
        my %result = ( errors => [] );
        if ($directive eq '.ORG')
        {
            unless (@$parameters == 1) # .ORG expects exactly one argument
            {
                push(@{$result{errors}}, 'Wrong number of arguments!');
            }
            else
            {
                my $retval = get_value($parameters->[0]);
                unless ($retval->{error})
                {
                    $result{next_address} = $retval->{value};
                }
                else
                {
                    push(@{$result{errors}}, $retval->{error});
                }
            }
        }
        elsif ($directive eq '.EQU') # .EQU does not change any address
        {}
        elsif ($directive eq '.DATA')
        {
            unless (@$parameters)
            {
                push(@{$result{errors}}, '.DATA-directive expects at least one parameter!');
            }
            else
            {
                $result{my_address}   = $address;
                $result{next_address} = @$parameters * 2 + $address;
            }
        }
        elsif ($directive eq '.TEXT')
        {
            unless (@$parameters == 1)
            {
                push(@{$result{errors}}, '.TEXT-directive expects exactly one parameter!');
            }
            else
            {
                $result{my_address}   = $address;
                $result{next_address} = (length($parameters->[0]) + 1) + $address - 2; # We need a terminating 0 byte.
                $result{next_address}++ if $result{next_address} % 2; # ...and we need an even number of bytes in total.
            }
        }
        elsif ($directive eq '.BSS')
        {
            unless (@$parameters == 1)
            {
                push(@{$result{errors}}, '.BSS-directive expects exactly one parameter!');
            }
            else
            {
                my $retval = get_value($parameters->[0]);
                if ($retval->{error})
                {   
                    push(@{$result{errors}}, $retval->{error});
                }   
                else
                {   
                    $result{next_address} += $retval->{value};
                }   
            }
        }
        else
        {
            push(@{$result{errors}}, "Internal error: Directive >>$directive<< recognized but not yet implemented!");
        }
        return \%result;
    },

    # Jump/shift/control instructions have no constants at all so they just increment the address by one:
    jump    => $no_constants,
    shift   => $no_constants,
    control => $no_constants,

    # Immediate instructions are easy since they always have one constant and thus increment the address by 2:
    immediate => $one_constant,

    # Immediate instructions without registers are treated equally:
    immediate_noreg => $one_constant,

    # Internal register loads are equally simple since these also require one constant:
    internal => $one_constant,

    #  Program/logical/cru/mpydiv/xop instructions may (!) have one constant parameter so they increment
    # the address by one or two:
    program => $maybe_one_constant,
    logical => $maybe_one_constant,
    cru     => $maybe_one_constant,
    mpydiv  => $maybe_one_constant,
    xopcru  => $maybe_one_constant,
);

my %constructors = (
    directive => sub {
        my ($address, $parameters, $directive, $labels) = @_;
        my %result = ( data => [], errors => [] );
        if ($directive eq '.ORG' or $directive eq '.EQU') # Already processed, do nothing
        {}
        elsif ($directive eq '.DATA')
        {
            for my $parameter (@$parameters)
            {
                my $retval = get_value($parameter, $labels);
                unless ($retval->{error})
                {
                    push(@{$result{data}}, $retval->{value});
                }
                else
                {
                    push(@{$result{errors}}, $retval->{error});
                }
            }
        }
        elsif ($directive eq '.TEXT')
        {
            my $text = $parameters->[0];
            $text =~ s/^"//;
            $text =~ s/"$//;
            $text =~ s/\\n/\x0d\x0a/g;
            $text .= chr(0);                      # Here comes the terminator.
            $text .= chr(0) if length($text) % 2; # We need an even number of bytes, so maybe a padding byte is necessary.
            push(@{$result{data}}, (ord(substr($_, 0, 1)) << 8) | ord(substr($_, 1, 1))) for (grep{$_}(split(/(..)/ms, $text)));
        }
        elsif ($directive eq '.BSS')
        {
            my $retval = get_value($parameters->[0], $labels);
            if ($retval->{error})
            {
                push(@{$result{errors}}, $retval->{error});
            }
            else
            {
                push(@{$result{data}}, 0) for 1 .. $retval->{value};
            }
        }
        else
        {
            push(@{$result{errors}}, "Extremely unexpected internal error: Directive >>$directive<< not implemented!");
        }
        return \%result;
    },
    arithmetic => sub {
        my ($address, $parameters, $instruction, $labels) = @_;
        my %result = ( data => [], errors => [] );
        if (@$parameters != 2)
        {
            push(@{$result{errors}}, 'Wrong number of arguments, 2 expected!');
        }
        else
        {
            my $source = get_operand($parameters->[0], $labels);
            if (@{$source->{errors}})
            {
                push(@{$result{errors}}, $_) for @{$source->{errors}};
            }
            else
            {
                my $destination = get_operand($parameters->[1], $labels);
                if (@{$destination->{errors}})
                {
                    push(@{$result{errors}}, $_) for @{$destination->{errors}};
                }
                else
                {
                    push(@{$result{data}}, (($instructions{$instruction}{opcode} & 0xf) << 12) |
                                           (($destination->{operand} & 0x3f) << 6) |
                                            ($source->{operand} & 0x3f));
                    push(@{$result{data}}, $source->{constant})      if defined($source->{constant});
                    push(@{$result{data}}, $destination->{constant}) if defined($destination->{constant});
                }
            }
        }
        return \%result;
    },
    jump => sub {
        my ($address, $parameters, $instruction, $labels) = @_;
        my %result = ( data => [], errors => [] );
        if (@$parameters != 1)
        {
            push(@{$result{errors}}, 'Wrong number of arguments, 1 expected!');
        }
        else
        {
            my $destination = get_operand($parameters->[0], $labels);
            if (!defined($destination->{constant}))
            {
                push(@{$result{errors}}, 'Could not find target!');
            }
            elsif (@{$destination->{errors}})
            {
                push(@{$result{errors}}, $_) for @{$destination->{errors}};
            }
            else
            {
                #  Just to make life more interesting, SBO/SBZ/TB belong to the JUMP-instruction format group 
                # but their argument is not a displacement but rather a constant value - so much for orthogonality. :-)
                my $displacement = {'SBO' => 1, 'SBZ' => 1, 'TB' => 1}->{uc($instruction)}
                                 ? $destination->{constant}
                                 : ($destination->{constant} - $address - 2) / 2;
                if ($displacement < -128 or $displacement > 127)
                {
                    push(@{$result{errors}}, "Displacement out of range: $displacement");
                }
                else
                {
                    $displacement &= 0xffff;
                    push(@{$result{data}}, (($instructions{$instruction}{opcode} & 0xff) << 8) |
                                            ($displacement & 0xff));
                }
            }
        }
        return \%result;
    },
    program => sub {
        my ($address, $parameters, $instruction, $labels) = @_;
        my %result = ( data => [], errors => [] );
        if (@$parameters != 1)
        {
            push(@{$result{errors}}, 'Wrong number of arguments, 1 expected!');
        }
        else
        {
            my $operand = get_operand($parameters->[0], $labels);
            if (@{$operand->{errors}})
            {
                push(@{$result{errors}}, $_) for @{$operand->{errors}};
            }
            else
            {
                push(@{$result{data}}, (($instructions{$instruction}{opcode} & 0x3ff) << 6) |
                     ($operand->{operand} & 0x3f));
                push(@{$result{data}}, $operand->{constant}) if defined($operand->{constant});
            }
        }
        return \%result;
    },
    shift => sub {
        my ($address, $parameters, $instruction, $labels) = @_;
        my %result = ( data => [], errors => [] );
        if (@$parameters != 2)
        {
            push(@{$result{errors}}, 'Wrong number of arguments, 2 expected!');
        }
        else
        {
            my $retval = get_operand($parameters->[0], $labels);
            if ($retval->{mode} ne 'register direct')
            {
                push(@{$result{errors}}, "Illegal addressing mode: >>$parameters->[0]<<, expected 'register direct'");
            }
            elsif (@{$retval->{errors}})
            {   
                push(@{$result{errors}}, $_) for @{$retval->{errors}};
            }
            else
            {
                my $register = $retval->{register};
                $retval = get_operand($parameters->[1]);
                if ($retval->{mode} ne 'symbolic')
                {
                    push(@{$result{errors}}, "Illegal addressing mode: >>$parameters->[0]<<, expected 'symbolic'.");
                }
                elsif (@{$retval->{errors}})
                {
                    push(@{$result{errors}}, $_) for @{$retval->{errors}};
                }
                else
                {
                    push(@{$result{data}},
                         ($instructions{$instruction}{opcode} << 8) | (($retval->{constant} & 0xf) << 4) | ($register & 0xf)
                        );
                }
            }

        }
        return \%result;
    },
    control => sub {
        my ($address, $parameters, $instruction) = @_;
        return { data => [ $instructions{$instruction}{opcode} << 5 ] };
    },
    immediate => sub {
        my ($address, $parameters, $instruction, $labels) = @_;
        my %result = ( data => [], errors => [] );
        unless (@{$parameters} == 2)
        {
            push(@{$result{errors}}, 'Wrong number of arguments, 2 expected!');
        }
        else
        {
            my $retval = get_operand($parameters->[0], $labels);
            if ($retval->{mode} ne 'register direct')
            {
                push(@{$result{errors}}, "Wrong addressing mode for operand: $retval->{mode}. Expected 'register direct'!");
            }
            elsif (@{$retval->{errors}})
            {
                push(@{$result{errors}}, $_) for @{$retval->{errors}};
            }
            else
            {
                my ($register) = $retval->{register};
                $retval = get_operand($parameters->[1], $labels);
                if ($retval->{mode} ne 'symbolic')
                {
                    push(@{$result{errors}}, "Wrong addressing mode for operand: $retval->{mode}. Expected 'symbolic'!");
                }
                else
                {
                    push(@{$result{data}}, ($instructions{$instruction}{opcode} << 4) | ($register & 0xf));
                    push(@{$result{data}}, $retval->{constant});
                }
            }
        }
        return \%result;
    },
    immediate_noreg => sub {
        my ($address, $parameters, $instruction, $labels) = @_;
        my %result = ( data => [], errors => [] );
        unless (@{$parameters} == 1)
        {
            push(@{$result{errors}}, 'Wrong number of arguments, 1 expected!');
        }
        else
        {
            my $retval = get_operand($parameters->[0], $labels); # A constant is expected.
            if ($retval->{mode} ne 'symbolic' or !defined($retval->{constant}))
            {
                push(@{$result{errors}}, "Wrong addressing mode for operand: $retval->{mode}. Expected 'symbolic'!");
            }
            elsif (@{$retval->{errors}})
            {
                push(@{$result{errors}}, $_) for @{$retval->{errors}};
            }
            else
            {
                push(@{$result{data}}, $instructions{$instruction}{opcode} << 4);
                push(@{$result{data}}, $retval->{constant});
            }
        }
        return \%result;
    },
    internal => sub {
        my ($address, $parameters, $instruction, $labels) = @_;
        my %result = ( data => [], errors => [] );
        unless (@{$parameters} == 1)
        {
            push(@{$result{errors}}, 'Wrong number of arguments, 1 expected!');
        }
        else
        {
            my $retval = get_operand($parameters->[0], $labels);
            if ($retval->{mode} ne 'register direct')
            {
                push(@{$result{errors}}, "Wrong addressing mode for operand: $retval->{mode}. Expected 'register direct'!");
            }
            elsif (@{$retval->{errors}})
            {
                push(@{$result{errors}}, $_) for @{$retval->{errors}};
            }
            else
            {
                my $register = $retval->{operand} & 0xf;
                my $opcode   = $instructions{$instruction}{opcode} & 0xfff;

                push(@{$result{data}}, ($opcode << 4) | $register);
            }
        }
        return \%result;
    },
    mpydiv => sub {
        my ($address, $parameters, $instruction, $labels) = @_;
        my %result = ( data => [], errors => [] );
        if (@$parameters != 2)
        {
            push(@{$result{errors}}, 'Wrong number of arguments, 2 expected!');
        }
        else 
        {
            my $retval = get_operand($parameters->[1], $labels);
            if (@{$retval->{errors}})
            {
                push(@{$result{errors}}, $_) for @{$retval->{errors}};
            }
            elsif ($retval->{mode} ne 'register direct') # The destination operand must be a register.
            {
                push(@{$result{errors}}, "Wrong destination mode: $retval->{mode}, expected 'register direct'.");
            }
            else
            {
                my $destination_register = $retval->{register}; # Register only, no need for T.
                my $opcode               = $instructions{$instruction}{opcode} & 0x3f;

                $retval = get_operand($parameters->[0], $labels); # Now determine the source operand.
                if (@{$retval->{errors}})
                {
                    push(@{$result{errors}}, $_) for @{$retval->{errors}};
                }
                else
                {
                    my $source_register = $retval->{operand} & 0x3f;
                    push(@{$result{data}}, ($opcode << 10) | ($destination_register << 6) | $source_register);
                    push(@{$result{data}}, $retval->{constant}) if defined($retval->{constant});
                }
            }
        }
        return \%result;
    },
    xopcru => sub { # XOP looks a lot like MPY/DIV but D is no longer a register but a constant - so much for orthogonality again.
        my ($address, $parameters, $instruction, $labels) = @_; 
        my %result = ( data => [], errors => [] );
        if (@$parameters != 2)
        {   
            push(@{$result{errors}}, 'Wrong number of arguments, 2 expected!');
        }   
        else 
        {   
            my $retval = get_operand($parameters->[1], $labels);
            if (@{$retval->{errors}})
            {   
                push(@{$result{errors}}, $_) for @{$retval->{errors}};
            }   
            elsif ($retval->{mode} ne 'symbolic')
            {   
                push(@{$result{errors}}, "Wrong addressing mode for D: $retval->{mode}, expected 'symbolic'.");
            }   
            elsif ($retval->{constant} < 0 or $retval->{constant} > 15)
            {
                push(@{$result{errors}}, "D out of range (0..15): $retval->{constant}.");
            }
            else
            {
                my $d      = $retval->{constant} & 0xf;
                my $opcode = $instructions{$instruction}{opcode} & 0x3f;

                $retval = get_operand($parameters->[0], $labels); # Now determine the source operand.
                if (@{$retval->{errors}})
                {   
                    push(@{$result{errors}}, $_) for @{$retval->{errors}};
                }   
                else
                {   
                    my $source_register = $retval->{operand} & 0x3f;
                    push(@{$result{data}}, ($opcode << 10) | ($d << 6) | $source_register);
                    push(@{$result{data}}, $retval->{constant}) if defined($retval->{constant});
                }   
            }
        }   
        return \%result;
    }
);

### Main program

my ($im, $list, $verbose);
GetOptions('im' => \$im, 'list' => \$list, 'verbose' => \$verbose);

#  Everything left in @ARGV are names of files to be processed. These files will be read in the first pass
# and an array containing one hash reference per source line is generated. The hashes representing the
# individual lines contain the different parts of the line (label, operation, parameters, comments) and
# will be used later to store the machine code, errors which occured during assembly and the like.
my $pass = 1;
print "Pass $pass, reading input files, building label/equ tables.\n" if $verbose;
my (@program, %labels, $errors);
for my $source (@ARGV)
{
    open my $input, '<', $source or die "Unable to open $source: $!\n";
    while (my $line = <$input>)
    {
        chomp $line;
        my $comment;
        $comment = $1 if $line =~ s/(;.*$)//;
        $line =~ s/\s+$//;

        # Somehow this simple parsing took an ugly turn - the following lines until %statement should be rewritten! (TODO)
        my ($label, $operation, $parameters) = $line =~ /^(\S*)\s+(\S*)\s+(.*)$/;

        # Ugly workaround for instructions without any parameters at all - these end up in $parameters instead of $operation:
        ($operation, $parameters) = ($parameters) if $parameters and !$operation;

        # A line may consist of a label only (with optional comment):
        my ($label_only) = $line =~ /^(\w+)(\s+;.*)?$/;
        $label = $label_only if defined($label_only);

        my $format = $instructions{uc($operation)}{format} if $operation;
        my $parameter_list = (defined($parameters) and $parameters =~ /^".*"$/)
                           ? [ $parameters ] 
                           : [ split(/\s*,\s*/, defined($parameters) ? $parameters : '') ];
        my %statement = (
            comment    => $comment,
            label      => $label, 
            operation  => $operation ? $operation : undef, # If undef, the line is treated as a comment-only line
            format     => defined($format) ? $format : '',
            parameters => $parameter_list,
            errors     => [],
            data       => [],
        );
        push @program, \%statement;

        if ($label)
        {
            if ($labels{$label})
            {
                $errors = 1;
                push(@{$statement{errors}}, "Redefinition of label >>$label<<!");
            }
            $labels{$label} = -1; # Dummy entry
        }
    }
    close $input;
}

#  The first "real" processing step concerns the calculation of addresses in the program which are necessary
# for building the label table (which also contains EQUs).
$pass++;
print "Pass $pass: Determining instruction/directive lengths and addresses.\n" if $verbose;
my $address = 0; # Default start address, may be overridden by .org-directive
for my $instruction (@program)
{
    next unless $instruction->{operation};
    my $determine_length = $instruction_lengths{$instruction->{format}};
    unless ($determine_length)
    {
        $errors = 1;
        push(@{$instruction->{errors}}, "Unkown instruction >>$instruction->{operation}<<");
        next;
    }
    my $result = $determine_length->(
        $address,
        $instruction->{parameters},
        uc($instruction->{operation}),
        \%labels);
    $instruction->{address} = $result->{my_address} if defined($result->{my_address});
    $address = $result->{next_address} if defined($result->{next_address});
    $errors = 1 if $result->{errors} and @{$result->{errors}};
    push(@{$instruction->{errors}}, $_) for @{$result->{errors}};
}

$pass++; # Given the addresses known from the previous step we can now build a hash table containing all labels and EQUs.
print "Pass $pass: Determining label addresses.\n" if $verbose;
$_->{label} and $labels{$_->{label}} = $_->{address} for @program;

$pass++; # Given the addresses known from the previous step we can now build a hash table containing all labels and EQUs.
print "Pass $pass: Generating constants defined by .EQU.\n" if $verbose;
for my $instruction (@program)
{
    next if !defined($instruction->{operation}) or uc($instruction->{operation}) ne '.EQU';
    if (defined($labels{$instruction->{label}}))
    {
        $errors = 1;
        push(@{$instruction->{errors}}, "Label $instruction->{label} redefined!");
        next;
    }
    my $retval = get_value($instruction->{parameters}[0], \%labels);
    if ($retval->{error})
    {
        $errors = 1;
        push(@{$instruction->{errors}}, $retval->{error});
        next;
    }
    $labels{$instruction->{label}} = $retval->{value};
}

$pass++; # Finally, we can now generate actual machine code.
print "Pass $pass: Generating machine code.\n" if $verbose;
for my $instruction (@program)
{
    next unless $instruction->{operation};
    my $constructor = $constructors{$instruction->{format}};
    next unless $constructor;
    my $result = $constructor->(
        $instruction->{address},
        $instruction->{parameters},
        uc($instruction->{operation}),
        \%labels);
    $instruction->{data} = $result->{data} if $result->{data};
    $errors = 1 if $result->{errors} and @{$result->{errors}};
    push(@{$instruction->{errors}}, $_) for @{$result->{errors}};
}

my $label_length = 17; # Length of labels for the printout.

if ($list)
{
    list_program(\@program, $label_length);
    list_labels(\%labels, $label_length);
}

die "\n!!! There were errors - no code generated !!!\n\n" if $errors;

generate_im(\@program) if $im;

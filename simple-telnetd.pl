#!/usr/bin/perl -w

#
# Мурашев Андрей
# среда,  5 мая 2011 г. 00:14:30
# simple-telnetd
#

=encoding utf8

=head1 Тестовое задание:

=over 4

=item

    Разработать демон simple-telnetd на языке Perl позволяющий удаленно
  запускать некоторое ограниченное подмножество команд и выводить пользователю результат их
  выполнения.
  Требования:
  1) simple-telnetd может запускать только разрешенные программы, которые
  перечислены в файле /etc/simple-telnetd.conf. Демон должен перечитывать этот файл и обновлять
  список разрешенных программ после поступления сигнала SIGHUP;
  2) Запускаемые программы могут
  иметь параметры командной строки, но simple-telnetd не должен поддерживать интерактивного
  взаимодействия пользователя с запускаемыми программами;
  3) Демон не обязан обрабатывать спец
  символы: ^C, ^D, и т.д.
  4) * В качестве параметра командной строки simple-telnetd может
  передаваться параметр timeout - максимальное время выполнения одной команды;
  5) * Желательно
  чтобы демон мог прослушивать не только tcp сокеты, но и локальные (например /tmp/simple-telnetd);
  6) * Как решить задачу ограничения запускаемых telnetd команд без написания подобного демона.
  Используя лишь штатные средства unix?

=back

=head1 Ответы

=over 4

=item

    Данный скрипт позволяет запускать демона с параметрами:
    -i -u -t time
    где -i и -u это режимы работы: INET или UNIX сокеты,
    а -t time - время работы скрипта в секундах, при -t 0,
    либо без этого параметра скрипт рабтает, пока его не отключит системный вызов
    INT KILL QUIT либо аналогичные.

=item *

    Также в данном скрипте реализована возможность по сигналу SIGHUP перечитвапть
    конфигурацию - доступные команды для клиентов. Данный файл называется
    simple-telnetd.conf и находиться по умолчанию в одной папке со скриптом,
    однако при изменений в скрипте данных о местоположения файла он может находиться
    в любом месте.

=item *

    С помощью стандартной, для UNIX систем программы telnet, осуществляется
    полноценный обмен для UNIX сокетов. Сокет создается в папке
    /tmp/myprog_PID_ПРОЦЕССА с именем 'catsock', местоположение
    файла-сокета меняется в скрипте на необходимое значение достаточно легко.

=item *

    В UNIX системах ограничение на запуск программ реализуется с помощью метода
    sudo. С помощью утилиты visudo можно менять перечень разрешенных команд,
    пользователей, которые имеют право пользоваться данным способом запуска команд.

=back

=cut

use strict;
use warnings;
#use diagnostics;

# что бы иметь возможность использовать "новые" фишки Perl
# в скрипте их нет, так что можно безболезненно эту прагму комментить
use 5.010;

# Подключение всех необходимых модулей
use Socket;
use IO::Socket;
use POSIX ();
use POSIX ":sys_wait_h";

use Carp;
use File::Spec::Functions;

use Net::hostent;    # для OO версии gethostbyaddr

# Сбразываем данные по мере поступления
$| = 1;

# Определяем перевод строки
my $EOL = "\015\012";

sub spawn;           # предварительное объявление

# Логгирование
sub logmsg { print "pid $$: @_ в ", scalar localtime, $EOL; }

# Можно сделать демона кросс-платформенным, так что бы exec всегда
# вызывал скрипт с правильным путем, независимо от того, как скрипт
# будет запущен.
#use File::Basename ();
#my $script = File::Basename::basename($0);
#my $SELF = catfile $FindBin::Bin, $script;

# процесс-демона
my $daemon = undef;

# Создаем процесс-демон
# fork создает новый процесс, который является копией текущего.
# Он возвращает PID дочернего процесса родительскому процессу,
# 0 дочернему процессу и undef, если вызов функции закочился неудачей.
$daemon = fork();
exit() if ($daemon);
die "Couldn't fork: $! " unless defined($daemon);

#################################################
# Порт на котором запускаем демона
my $port = 10023;

# Для подстраховки создаем все переменные пустыми.
# Массив для хранения log'ов деток
my @logs = ();

# Хеш для хранения pid'ов детишек
my %Children = ();

# Переменные для детишек и
my $child = undef;

# Время жизни сервера
my $timeout = 0;

# Файл конфигурации с набором команд,
# которые обрабатывает наш сервер
# На FreeBSD правильнее будет использовать PREFIX = /usr/local
my $config = "/usr/local/etc/comand-telnetd.conf";

# Для определения местоположения скрипта
# (что бы сделать в ней же лог работы)
use FindBin ();

# в этой же папке создаем файл лога(это можно переопределить позже пори необходимости)
my $log_path = catfile $FindBin::Bin;    # unless ($daemon);
$log_path = "$log_path/log";

# Для тестов используем текущую директорию
$config = "./comand-telnetd.conf" unless ( -s ($config) );
unless ( -e $log_path ) {
  mkdir $log_path;
}

# Массив где хранится список команд
my @commands = ();

## Переменные для UNIX-сокета
my $temp_directory = "/tmp/myprog.$$";    # Каталог для временных файлов
mkdir $temp_directory, 0777 or die "Cannot create $temp_directory: $!";

my $NAME = 'catsock';
$NAME = "$temp_directory/$NAME";
#unlink($NAME) if ($NAME);
my $uaddr = sockaddr_un($NAME);
my $proto = getprotobyname('tcp');

# Обработка ожидания "выключения " детей(child)
$SIG{CHLD} = \&shiner_children;

# Обработка сигналов выключения демона
$SIG{INT} = $SIG{QUIT} = $SIG{TERM} = \&kill_server;    # лучший способ

# Обработка команды HUP(перечитать конфигурацию)
$SIG{HUP} = \&read_conf;

# Заполняем массив разрешенных команд до старта сервера
&read_conf();

# Создаем связь с новым терминалом
POSIX::setsid() or die __LINE__ . "Can't start a new session $!";

# Интернет-сокет или сервер
my $server = undef;
my $inet   = 0;
my $unix   = 0;
my $client = undef;

# Создаем копию массива аргументов
my @args = @ARGV;
my %arg  = ();

# Проверяем наличие аргументов командной строки
# заполняем хеш значениями
my $i = 0;
&shell_args( \@ARGV, \%arg );

# Массив для потомков
my @child = ();

if ( grep /-i/, @args ) {

  # Создаем интернет сокет на порту 23
  #
  $server = new IO::Socket::INET(
    LocalPort => $port,
    TYPE      => SOCK_STREAM,
    Reuse     => 1,
    Listen    => 10,
  ) or die "Couldn't be a tcp server on port $port: $@ ";
  $inet = 1;

} elsif ( grep /-u/, @args ) {
  # Создаем UNIX сокет по адресу
  # /tmp/myprog.PID_ПРОЦЕССА

  $server = undef;
  $server = IO::Socket::UNIX->new(
    Local  => "$NAME",
    Type   => SOCK_STREAM,
    Listen => 5,
  ) or die "Can't create socket to UNIX daemon: $@";

  logmsg "сервер запущен на $NAME";
  $unix = 1;
} else {
  die "Usage: $0 (-i|-u) to select the server type";
}

# Помещаем PID процесса в файл лога.
$daemon = $$;
my $parent_log = $$ . '.log';

$parent_log = "$log_path/$parent_log";
open( LOG, ">>$parent_log" ) or die __LINE__ . ": Can't open $parent_log  $! $EOL";
print LOG $daemon . $EOL;
close LOG or die __LINE__ . ": Can't close $parent_log  $! $EOL";
my $child_log  = undef;

### ### ### ### ### ### ### ### ### ### ### ### ### #####
# ALGORITM ALGORITM ALGORITM ALGORITM ALGORITM ALGORITM #
### ### ### ### ### ### ### ### ### ### ### ### ### #####

my $hostinfo   = undef;
my $clientinfo = undef;

# Сервер работает пока его не вырубит TERM или &timeout().
until ($timeout) {

  &timeout();
  &inet_socket();

}

# Функция создания клиента inet & unix
#
sub inet_socket {

  # Обрабатываем входящие подключения
  while ( $client = $server->accept() ) {

    # Для unix сервера этот запрос вызывает фатальное
    # для сервера исключение - он просто падает
    # тут есть описание проблемы и фиксы(патчи)
    # http://irclog.perlgeek.de/mojo/2010-08-31
    # http://markmail.org/message/djciqnqgjlwmi47b
    if ($inet) {
      #$hostinfo = gethostbyaddr( $client->peerpath );
      $hostinfo = gethostbyaddr( $client->peeraddr() );
    }
    elsif ($unix) {
      $hostinfo   = $server->sockname();
      $clientinfo = $server->hostpath();
      #$hostinfo = gethostbyaddr( $client->sockname );
    }
    #print STDERR q|str: | . __LINE__ . q| $hostinfo : | . $hostinfo . $EOL;

    # Того, который постучался, отделяем в отдельный процесс
    defined( my $child = fork() ) or die __LINE__ . ": Can't fork new child $!";
    if ($child) {
      &child_inet($child);
    }

    # Родительский процесс идет в конец и ждет следующего подключения
    next if ($child);

    # Дочернему процессу копия сокета не нужна, её закрываем
    if ( $child == 0 ) {
      close($server);
    }

    # Очистка буфера
    $client->autoflush(1);
    my $is_comm = 0;
    print $client "Command :$_$EOL" for (@commands);
    print $client "Command :";

    #$SIG{HUP} = \&read_conf;
    &read_client_inet($is_comm);

    exit;
  } continue {
    close($client);
    #shutdown($client, 2);
  }
}

### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ##
# FUNCTIONS #  FUNCTIONS # FUNCTIONS # FUNCTIONS # FUNCTIONS #
### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ##
# Вспомогательные функции
#
# Функция для отключения сервера по таймауту
#
sub timeout {
  $timeout = $arg{timeout};
  if ( defined $timeout ) {
    for ( $i = 0 ; $i <= $timeout ; $i++ ) {
      sleep 1;
      $timeout = $timeout - 1;

      #print STDERR q|Осталось | . $timeout . q| секунд...| . $EOL;
      `kill -9 $$` if $timeout == 0;
    }
  }
}

# Функция чтения команд от клиента inet
#
sub read_client_inet() {
  my $is_comm = $_[0];

  # Считываем комады от клиента построчно
  while (<$client>) {

    # Если строка пустая переходим в конец блока
    next unless /\S/;

    # Запоминаем полную введенную строку, к примеру df -h
    my $full_str = $_;
    chomp($full_str);

    # Переменная - имя команды, к примеру df
    my $comm = undef;

    # Переменная - набор параметров, к примеру -h
    my $param = undef;

    # Разбиваем введенную строку на имя команды и параметры
    # Сравнение имени команды с набором разрешенных команд
    # Просматриваем разрешенные команды в конфигурационном файле
    if ( $full_str =~ /(^[\w+])(\s+)(.*)(\s*)/ ) {
      $comm  = $1;
      $param = $3;
    } elsif ( $full_str =~ /(\w+)/ ) {
      $comm  = $1;
      $param = undef;
    } else {
      ( $comm, $param ) = ( undef, undef, );
    }

    # Просматриваем разрешенные команды в конфигурационном файле
    $is_comm = 1 if ( grep /$comm/, @commands );

    # Если команда разрешена - выполняем её
    if ($is_comm) {
      if (/help/) {
        print $client "$_$EOL" for (@commands);
      } elsif (/quit/) {
        exit;
      } else {
        my @lines = ();
        if ($param) {
          @lines = qx($comm $param);
        } else {
          @lines = qx($comm);
        }
        foreach (@lines) {
          print $client $_;
        }
      }
    } else {
      print $client "Comand not found!${EOL}Print help for HELP$EOL";
      next;
    }
  } continue {
    print $client "Command :";
    $is_comm = 0;

  }
}

# Функция логгирования клиентов
#
sub child_inet {
  my $child = $_[0];
  if ($inet) {
    $hostinfo   = $hostinfo->name;
    $clientinfo = $client->peerhost;
    logmsg "Установлено соединение с Сервером [" . $hostinfo . "] на порт $port";
    logmsg "Установлено соединение с Клиентом [" . $clientinfo . "]";
  } elsif ($unix) {
    $hostinfo   = $server->sockname();
    $clientinfo = $server->hostpath();
    logmsg "Установлено соединение с Сервером [" . $hostinfo . "]";
    logmsg "Установлено соединение с Клиентом [" . $clientinfo . "]";
  }

  print $client "Добро пожаловать на " . $hostinfo . "!$EOL Наберите help для вывода списка команд.$EOL";

  $Children{$child} = $child;
  $log_path  = catfile $FindBin::Bin if ($child);
  $log_path  = "$log_path/log";
  $child_log = "$log_path/$child" . '.log';

  open( FILECONF, ">>$child_log" ) or die __LINE__ . ": Can't open $child_log  $! $EOL";
  push( @logs, $child );
  print FILECONF $child . $EOL;
  close(FILECONF) or die __LINE__ . ": Can't open $child_log  $! $EOL";

  print q|str: | . __LINE__ . q| Данные о клиенте | . $child . q| занесены в лог| . $EOL;

}

# Функция наполнения массива и хеша аргументами
# командной строки.
sub shell_args {
  my $args = $_[0];
  my $arg  = $_[1];
  my ( $comm, $param ) = ( undef, undef, );
  if (@$args) {

    #print STDERR q|str: | . __LINE__ . q| Size $#$args = | . ( $#$args + 1 ) . $EOL . $EOL;
    my $ar = undef;
    for ( 0 .. $#$args ) {
      if ( defined( $$args[$i] )
        && defined( $$args[ $i + 1 ] )
        && ( "$$args[$i] $$args[$i+1]" =~ m|-\w\s[\d+]| )
        && ( $$args[$i] =~ /-[t]/ or $$args[ $i + 1 ] =~ /-[t]/ ) )
      {
        $ar = "$$args[$i] $$args[$i+1]";

        #print STDERR q|str: |.__LINE__.q| $ar = |.$ar.$EOL;
        $$arg{timeout} = $$args[ $i + 1 ];
      }
      $i++;
    }
  }

}

# Функция обработчик сигнала CHLD
# для уборки процессов зомби
# Кто-то умер. Уничтожать зомби, пока они остаются.
# Проверить время их работы.
sub shiner_children {

  my $child;
  my $start;

  # Проверяем потомков, которые уже отработали
  # Пока есть потомки, ждем окончания их работы
  while ( ( $child = waitpid( -1, WNOHANG ) ) > 0 ) {

    # Если есть child в хеше %Children
    if ( $start = $Children{$child} ) {
      # вычисляем время его работы
      my $runtime = time() - $start;
      printf "Потомок с pid'ом $child работал: %dm%ss$EOL", $runtime / 60, $runtime % 60;
      # удаляем из хеша pid потомка
      #delete $Children{$child};
      delete( $Children{$child} );
    } else {
      print "Потомок $child вышел со статусом $? $EOL";
    }
  }

  $SIG{CHLD} = \&shiner_children;
}

###
# Функция обработчик сигналов INT, TERM, QUIT
# перехватывает системные вызовы
# и срабатывает перед этими сигналами

sub kill_server {
  my $signame = $_[0];
  $timeout = 1;

  # выключаем потомков
  &kill_child($signame);

  # убираем зомби
  $SIG{CHLD} = \&shiner_children;

  #unlink 'catsock' if ( grep /-u/, @args );
  #logmsg "END: unlink catsock";

  my $log_path = catfile $FindBin::Bin;
  $log_path = "$log_path/log";

  opendir DIR, "$log_path" || die __LINE__ . ": Can't open dir $log_path $!" . $EOL;
  while ( my $file = readdir DIR ) {
    next if ( $file eq '.' || $file eq '..' );
    unlink "$log_path/$file" || die __LINE__ . ": Can't unlink file $log_path/$file! $!" . $EOL;
  }
  closedir DIR || die __LINE__ . ": Can't close dir $log_path $!" . $EOL;
  #logmsg "END: unlink $log_path/*";

  # Чистим за собой
  #&clean_up;
  # выключаем сервер
  shutdown ($server, 2) if ($server);

  # Чистим, если процесс родительский
  if ( grep /$$/, ($NAME) ) {
    &clean_up;
  }

  die "Пришел сигнал SIG$signame для процесса с номером: $$" . $EOL . "interrupted, exiting...$EOL";
}

# Функция выключения child
# параметры(pid'ы) беруться из @logs
#
sub kill_child {
  my $signame = $_[0];

  # удаляем зомби
  $SIG{CHLD} = \&shiner_children;
  for (@logs) {
    if ( grep /$_/, ( keys %Children ) ) {
      my $child = $_;
      `kill -$signame $child`;
      warn "Пришел сигнал SIG$signame для $child";

    }
  }
}

# Функция обработчик сигнала HUP
# перечитывает конфигурационный файл
# и обновляет массив @commands
sub read_conf {
  open( FILECONF, $config ) or die __LINE__ . ": Can't open $config  $! $EOL";
  @commands = ();
  while (<FILECONF>) {
    chomp;
    push( @commands, $_ );
  }
  close(FILECONF) or die "Can't close $config  $! $EOL";
  # гасим потомков
  &kill_child('TERM');

}

# Функция для очистки создаваемых сокетов
#
sub clean_up {
  unlink glob "$temp_directory/*";
  rmdir $temp_directory;
}

# Конец нормального выполнения
# Чистим, если процесс родительский
  if ( grep /$$/, ($NAME) ) {
    &clean_up;
  }

END {
# Конец НЕнормального выполнения
# Чистим, если процесс родительский
#  if ( grep /$$/, ($NAME) ) {
#    &clean_up;
#  }
}

1;

__END__
> cat comand-telnetd.conf
help
quit
cp
ps
pwd
ipconfig
ls
sleep
echo
pwd
uname

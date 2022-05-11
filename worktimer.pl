#!/usr/bin/perl

# worktimer.pl       : Консольный тайм-менеджер
# Автор              : Виталий Клименков
# Домашняя страничка : https://vklimenkov.ru
# Гитхаб             : https://github.com/vklimenkov/perl-worktimer


use strict;
use warnings;
use Data::Dumper;
use Pod::Usage qw(pod2usage);
use FindBin qw($Bin);

use DBI;
use Date;
use Encode;

# ----------------------------------- БД -----------------------------------
# Файл БД лежит в той же папке, что и скрипт
# Если файла нет, он будет создан
my $db_name = $Bin.'/worktimer.db';
my $db = DBI->connect("dbi:SQLite:dbname=$db_name","",""); 

# создаём таблицы, если их ещё нет
# в первой таблице хранятся задачи
$db->do("
	create table if not exists task (
		`id` INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
		`name` varchar(255) NOT NULL DEFAULT '',
		`parent_id` INTEGER NOT NULL DEFAULT 0
	)"
); 
# во второй таблице лог работы: когда, сколько, над какой задачей работали
$db->do("
	create table if not exists worklog (
		`id` INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
		`task_id` INTEGER unsigned NOT NULL DEFAULT 0,
		`started` INTEGER NOT NULL default 0,
		`stoped` INTEGER NOT NULL default 0,
		`spent` INTEGER NOT NULL DEFAULT 0
	)"
); 

# ---------------------------------------------------------------------------

# не стал заморачиваться с модулями типа Getopt
# т.к. разбор параметров вызова достаточно простой

# случаи, когда надо вывести справку
if($ARGV[0] && $ARGV[0] =~ /help/){
	# отдаём общий хелп
	pod2usage();
} elsif ($ARGV[1] && $ARGV[1] =~ /help/){
	# по имени команды проверяем существование одноименной функции
	# и то, что она не "приватная"
	if($ARGV[0] && exists(&{$ARGV[0]}) && $ARGV[0] !~ /^_/){
		# отдаём раздел справки по конкретной команде
		pod2usage(-sections => 'COMMANDS/'.$ARGV[0], -verbose => 99);
	} else {
		print "wrong command: ".$ARGV[0]."\n\n";
		pod2usage();
	}

}

# первый аргумент - это всегда команда
if(!$ARGV[0] || $ARGV[0] eq 'current'){
	current();
} elsif ($ARGV[0] eq 'start'){
	start();
} elsif ($ARGV[0] eq 'stop'){
	stop();
} elsif ($ARGV[0] eq 'report'){
	report();
} elsif ($ARGV[0] eq 'list'){
	list();
} elsif ($ARGV[0] eq 'add'){
	add();
} 



sub start {
	# стартуем новый таск

	# открыто может быть не более 1 таска одновременно
	# так что если есть открытый, закрываем
	stop();

	# получаем id нового таска
	my $id = _get_task_id($ARGV[1]);

	# создаём новую запись в worklog
	$db->do(qq~
		insert into worklog(task_id, started) values (?,?)
	~, undef, $id, time());

	print "start task: "._taskname($id)."\n";
}


sub stop {
	# останавливаем текущий таск, подсчитываем потраченное время

	my $opened = $db->selectall_arrayref(qq~
		select * from worklog
		where started != 0 and stoped = 0
	~, {Slice=>{}});

	if(scalar(@$opened)>1){
		# скрипт не в состоянии решить эту проблему, нужно 
		# руками править БД.
		die 'Too many opened tasks';
	}
	if(scalar(@$opened)){
		$db->do(qq~
			update worklog set stoped=?, 
			spent=(?-started)
			where id = ?
		~, undef, time(), time(), $opened->[0]->{id});
		my $spent = _humantime(time() - $opened->[0]->{started});
		my $name = _taskname($opened->[0]->{task_id});
		print "stop task: $name, spent: $spent\n";
	}
}



sub current {
	# выводим текущий таск или предыдущий, если нет текущего
	my $opened = $db->selectall_arrayref(qq~
		select * from worklog
		where started != 0 and stoped = 0
	~, {Slice=>{}});
	if(scalar(@$opened)>1){
		die 'Too much opened tasks';
	}
	if(scalar(@$opened)){
		my $name = _taskname($opened->[0]->{task_id});
		my $spent = _humantime(time() - $opened->[0]->{started});
		print "current task: $name, spent: $spent\n";
	} else {
		print "no opened tasks\n";
		print "previous task: "._taskname(_get_task_id())."\n";
	}
}


sub report {
	# вывод отчёта

	#  ------------------ определяем период ---------------------------------
	my ($d1, $d2);
	if(!$ARGV[1]){
		$d1 = Date::today(); 
	} else {
		$d1 = _date_from_arg($ARGV[1]);
	}
	if($ARGV[2]){
		$d2 = _date_from_arg($ARGV[2]);
	} else {
		$d2 = $d1->clone();
	}
	# теперь у даты1 сбрасываем чч:мм:сс в нули
	# а дату 2, наоборот, переводим в конец дня
	$d1->truncate;
	$d2->truncate;
	$d2 = $d2 + '23h 59m 59s';

	# выведем период. если даты совпадают, то только одну
	my $d1_str = $d1->to_string(Date::FORMAT_DOT);
	my $d2_str = $d2->to_string(Date::FORMAT_DOT);
	print "REPORT for $d1_str".($d2_str ne $d1_str ? " - $d2_str" : "")."\n";

	# ------------------ поиск всех дочерних тасков за период --------------------

	# поскольку всё это устроено иерархически,
	# одельные строки могут суммироваться, причём в разном порядке
	# поэтому один раз достаём лог и больше его не трогаем
	# это гарантирует, что каждое время будет посчитано один раз в каждой ветке
	my $hash = $db->selectall_hashref(qq~
		select task_id, sum(spent) spent
		from worklog
		where (started>=? or (started=0 and stoped>=?)) and stoped<=?
		group by task_id
	~, 'task_id', {Slice=>{}}, $d1->epoch_sec(), $d1->epoch_sec(), $d2->epoch_sec());

	# выведем, над каким количеством задач мы вообще работали за период
	print "TASK COUNT ".scalar(keys %$hash)."\n";

	# теперь рекурсивно строим иерархию
	# пока база не очень большая, можно тупо перебирать все таски
	# и смотреть, была ли по ним активность в периоде
	# ну а в дальнейшем можно их как-то отправлять в архив и работать только с активными
	# итак, создаём корневой узел, и от него рекурсивно простраиваем ветки
	my $structure = {name=>'TOTAL', id=>0, level=>0};
	_recursive_report($structure, $hash);

	# а теперь всё это красиво напечатаем
	_recursive_print([$structure]);

	# если вызов без аргументов, то посчитаем средние часы за неделю
	if(!$ARGV[1]){
		# определяем дату понедельника
		my $wd = $d1->ewday;
		my $start = $d1->epoch_sec() - ($wd-1)*86400;
		my $sum = $db->selectrow_array(qq~
			select sum(spent)
			from worklog
			where (started>=? or (started=0 and stoped>=?)) and stoped<=?
		~, undef, $start, $start, $d2->epoch_sec());
		$wd = 5 if ($wd>5); # если смотрим в субботу или воскресенье
		print "AVERAGE ($wd days): "._humantime(int($sum/$wd))."\n";
	}

	# выведем текущую задачу
	print "\n";
	current();

}



sub add {
	# добавляем в лог запись
	# время должно быть задано

	unless($ARGV[1] && $ARGV[2]){
		# TODO вывести хелп
		die 'Need two arguments: task name/id and time spent';
	}

	my $id = _get_task_id($ARGV[1]);
	my $tt = _get_time($ARGV[2]); # время в секундах

	$db->do(qq~
		insert into worklog(task_id, stoped, spent) values (?,?,?)
	~, undef, $id, time(), $tt);

	print "add task: "._taskname($id).", time: $tt\n";
}



sub list {
	# выводим все задачи, над которыми работали в течение заданного периода
	# по дефолту неделя
	my $s = $ARGV[1]||'7d';
	my $list;
	if($s eq 'all'){
		# особый период - all, выведет все задачи
		print "PERIOD: ALL\n";
		$list = $db->selectall_arrayref(qq~
			select id from task where 1 order by id
		~, {Slice=>{}});
	} else {
		my $tt = _get_time($s);
		unless($tt){
			die 'bad period';
			# TODO вывести хелп по этой команде
		}
		print "PERIOD: $s\n";
		$list = $db->selectall_arrayref(qq~
			select t.id, sum(wl.spent) sp
			from task t
			join worklog wl on wl.task_id = t.id 
			where wl.stoped>=?
			group by t.id
			order by t.id
		~, {Slice=>{}}, time()-$tt);
	}
	foreach my $i (@$list){
		print "$i->{id}   "._taskname($i->{id}).($i->{sp}?" "._humantime($i->{sp}):'')."\n";
	}
	print "\n";
	# в конце выведем текущую задачу
	current();
}

################### ПРИВАТНЫЕ ФУНКЦИИ #######################################
# имеются в виду функции, которые не отрабатывают команды юзера
# а обслуживают основной функционал


sub _true_length($) {
	# возвращает истинную длину строки в символах при отображении на экране
	# чтобы сделать красивое форматирование вывода
	return length(decode('utf8',shift));
}


sub _taskname {
	# на вход получает id таска, возвращает его название
	# причём всю цепочку узлов
	my $id = shift;
	my @arr;
	while($id){
		# идём по цепочке родителей (parent_id)
		# пока не найдём корневой таск
		# по пути всё складываем в массив @arr
		my $row = $db->selectrow_hashref(qq~
			select * from task where id = ?
		~, undef, $id);
		unless($row && $row->{id}){
			# битая ссылка в parent_id, нарушена целостность данных
			# ситуация требует ручного вмешательства в БД
			die "Bad task id $id";
		}
		push(@arr, $row->{name});
		$id = $row->{parent_id};
	}
	return join('/', reverse @arr);
}



sub _humantime {
	# превращает время в секундах в человекочитаемую строку
	# в формате <часы>h<минуты>m
	# самый удобный вывод времени для задач. секунды - это лишнее
	# а выводить дни неудобно, т.к. нагрузка обычно в часах
	# типа 40 часов в неделю

	my $t = shift;

	my $str = '';
	my $hh = int($t/3600);
	if($hh){
		$str .= $hh."h";
		$t -= $hh*3600;
	}
	# округляем до ближайшей минуты, поэтому +30
	my $mm = int(($t+30)/60);
	if($mm){
		$str .= $mm."m";
	}
	return $str;
}



sub _get_time {
	# функция, обратная himantime
	# на вход получаем "человеческое" представление времени
	# должны превратить его в секунды
	# отличие в том, что тут поддерживаем больше форматов

	my $str = shift;

	if($str=~/(\d+):(\d{2}):(\d{2})/){
		# формат HH:MM:SS
		return $3 + ($2*60) + ($1*3600);
	} elsif ($str =~ /^\d+$/) {
		# это просто секунды
		return $str;
	} else {
		# формат <дни>d<часы>h<минуты>m<секунды>s
		my $tt = 0;
		if($str =~ m/(\d+)d/g){
			$tt += 86400*$1;
		}
		if($str =~ m/(\d+)h/g){
			$tt += 3600*$1;
		}
		if($str =~ m/(\d+)m/g){
			$tt += 60*$1;
		}
		if($str =~ m/(\d+)s/g){
			$tt += $1;
		}
		return $tt;
	}
}



sub _date_from_arg {
	my $s = shift;
	# переводим строку в формат Date
	# пока что поддерживаем только YYYY-MM-DD
	# но в будущем появятся относительные даты и какие-то сокращения
	unless($s =~ /^\d{4}\-\d{2}\-\d{2}$/){
		die 'Wrong date format';
	}
	return Date->new($s);
}



sub _get_task_id {
	# на вход получаем ID или название таска
	# ищем его в базе, при необходимости создаём
	# возвращаем id
	my $arg = shift;

	if(!$arg){
		# без аргумента - подразумевается самый последний таск
		my $row = $db->selectrow_hashref(qq~
			select task_id from worklog order by stoped desc limit 1
		~);
		unless($row && $row->{task_id}){
			die "No tasks";
		}
		return $row->{task_id};
	} elsif($arg=~/^\d+$/) {
		# получили id таска, нужно только его проверить
		my $t = $db->selectrow_hashref(qq~
			select * from task where id = ?
		~, undef, $arg);
		if($t && $t->{id}){
			return $t->{id};
		} else {
			die "Wrong task id";
		}
	} else {

		# самый сложный вариант - название таска
		# может быть несколько уровней иерархии разделённых косой чертой
		# например: задача/подзадача/подпункт_подзадачи

		# поэтому, нам нужно аккуратно пройтись по цепочке
		# и создать недостающие узлы
		my @nodes = split(/\//, $arg);
		my $id = 0;
		foreach my $n (@nodes){
			# сначала ищем таск с таким именем в базе
			my $row = $db->selectrow_hashref(qq~
				select * from task where name = ? and parent_id = ?
			~, undef, $n, $id);

			if($row && $row->{id}){
				$id = $row->{id};
			} else {
				# создаём таск
				$db->do(qq~
					insert into task(name, parent_id) values (?,?)
				~, undef, $n, $id);
				$id = $db->last_insert_id(undef, undef, 'task', undef);
				print "create task $id $n\n";
			}
		}
		return $id;
	}
}



sub _recursive_report {
	my ($str, $hash) = @_;

	# проверили, может, по нему самому есть записи в логе
	$str->{spent} = $hash->{$str->{id}}->{spent}||0;

	# достали все дочерние таски
	my $list = $db->selectall_arrayref(qq~
		select id, name from task where parent_id = ? order by id
	~, {Slice=>{}}, $str->{id});

	# в этот массив будем складывать дочерние с ненулевым временем
	# остальные не отображаются в отчёте
	my @arr;

	foreach my $row (@$list){
		# проставляем ему уровень
		$row->{level} = $str->{level}+1;
		# считаем по нему время (заодно дополняя дочерними)
		_recursive_report($row, $hash);
		if($row->{spent}){
			# плюсуем время
			$str->{spent} += $row->{spent};
			# помещаем в массив
			push(@arr, $row);
		}
	}
	if(scalar(@arr)){
		# если есть дочерние с временем, посчитаем по ним процентаж
		foreach my $row (@arr){
			$row->{perc} = int($row->{spent}/$str->{spent}*100);
		}
		# и добавляем их в структурку
		$str->{children} = \@arr;
	}
}



sub _recursive_print {
	my $a = shift;
	# возможные ограничения по level
	my $max_level = 10;
	if($ARGV[3] && $ARGV[3]=~/^l(\d+)$/){
		$max_level = $1;
	}
	foreach my $row (@$a){
		# печатаем текущую строку:
		print "--"x$row->{level}; # отступ
		# выводим id если он не нулевой
		my $nm = ($row->{id} ? "id".$row->{id}." " : "").$row->{name};
		print $nm;
		# расчитываем отступ
		my $ll = 30 - _true_length($nm) - 2*$row->{level};
		$ll = 1 if ($ll<=0);
		print " "x$ll;
		# продолжаем: время и проценты
		print _humantime($row->{spent}).($row->{perc}?" ($row->{perc}%)":"");
		print "\n";
		# и теперь отправляем на печать дочерние
		if($row->{children} && $row->{level}<$max_level){
			_recursive_print($row->{children});
		}
	}
}


=head1 NAME

worktimer - консольный таск-менеджер

=head1 SYNOPSIS

perl worktimer.pl <command> [options]

Рекомендую прописать алиас в .bashrc:

alias worktimer='perl <путь-к-файлу>/worktimer.pl'

Тогда можно вызывать таск-менеджер из любой папки:

worktimer <command> [options]

Правила игры такие: может быть только один октрытый (текущий) таск единовременно.
Таски в командах можно задавать и названием, и по id. 
Над одним и тем же таском можно начинать и останавливать работу несколько раз.
Поддерживается иерархия задач, разделитель косая черта: задача/подзадача 
это удобно для вывода отчёта. Длинные названия задач я предпочитаю писать
через нижнее подчёркивание, чтобы не связываться с кавычками, например: 
это_длинное_название_сложной_задачи

=over 4

=item Засекаем время начала работы:

worktimer start <название задачи>

=item Останавливаем работу над задачей:

worktimer stop

=item Показать текущую задачу и потраченное на неё время:

worktimer current

=item Если не засекли время через worktimer start, а задачу добавить надо:

worktimer add <название задачи> <потраченное время>

=item Отчёт за период

worktimer report <дата начала> [<дата окончания>]

=item Список всех задач за период

worktimer list [<период>]

=item Вывести более подробную справку по одной из команд:

worktimer <команда> help

=back


=head1 COMMANDS

=head2 start

Начинает работу над новой задачей

=over 4

=item worktimer start 11

Стартовать задачу id=11

=item worktimer start задача/подзадача/подподзадача

Стартовать задачу 'подподзадача'. Если родительские узлы ('задача', 'подзадача')
отсутствуют, они будут созданы автоматически

=item worktimer start

Без указания задачи будет заново стартована последняя задача

=back


=head2 stop

Останавливает текущую задачу, выводит потраченное время

=head2 current

Выводит текущую задачу и потраченное в данной сессии время.
Если текущей задачи нет, выведет предыдущую. 

=head2 add

Добавляет в лог работы задачу и потраченное время. Также как в команде start, 
задача может быть передана или id или именем. 
Следующий аргумент - потраченное время, допустимо несколько форматов:

=over 4

=item <часы>:<минуты>:<секунды>

Часы-минуты-секунды

=item <целое число>

Количество секунд

=item <дни>d<часы>h<минуты>m<секунды>s

В любой комбинации, например: 1h - один час, 2d10m - два дня и десять минут

=back

=head2 report

Выводит отчёт за период. Считает по каждой задачи суммарное потраченное время, 
а также процент времени в рамках иерархии. В конце выводит текущую задачу 
(как команда current)

Без аргументов - отчёт за сегодняшний день, с одним аргументом - за указанную дату,
с двумя аргументами - за период. Даты задаются в формате YYYY-MM-DD

Также возможен третий аргумент - ограничение по уровню иерархии. Иногда это
полезно, если полный отчёт со всеми уровнями иерархии слишком громоздкий 
и трудно читаемый, 
а надо быстро посмотреть распределение времени по корневым задачам.

Cледующая команда выводит отчёт за период с 3 по 7 июля, только первый уровень

worktimer report 2022-07-03 2022-07-07 l1

=head2 list

Выводит список задач, над которыми работали за указанный период. 
По-умолчанию 7 дней. Можно задать произвольный период, например, 
10 дней (точнее, это 10 суток назад, начиная с текущего момента)

worktimer list 10d

Форматы времени могут быть такие же, как в команде add

Также можно передать особый период: all. Все задачи за всё время

=cut

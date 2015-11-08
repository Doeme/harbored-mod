.PHONY: all clean doc

DMD?=dmd

SRC:=src/*.d\
	libddoc/src/ddoc/*.d\
	libdparse/src/std/*.d\
	libdparse/src/std/d/*.d\
	dmarkdown/source/dmarkdown/*.d

OBJ:=$(patsubst %.d,%.o,$(wildcard $(SRC)))

IMPORTS:=-Ilibdparse/src\
	-Ilibddoc/src\
	-Idmarkdown/source\
	-Jstrings\
	-Isrc
FLAGS:=-O -gc -release -inline # keep -inline; not having it triggers an optimizer bug as pf 2.066

all:./bin/hmod

./bin/hmod: $(OBJ)
	$(DMD) $(IMPORTS) $(FLAGS) $^ -of$@

%.o:%.d
	$(DMD) $(IMPORTS) $(FLAGS) -c $^ -of$@

clean:
	rm -rf bin/

doc: ./bin/hmod
	./bin/hmod src/

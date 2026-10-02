# Crossbar switch -- every check in one place (Linux / WSL, OSS CAD Suite).
#
#   make lint | sim | regress | formal | mutants | all
#   make sim N=8 VOQ=0 SEED=3 DEPTH=16

N     ?= 4
VOQ   ?= 1
SEED  ?= 1
DEPTH ?= 4

.PHONY: all lint sim regress formal mutants clean

all: lint regress formal mutants

lint:
	bash scripts/lint.sh

sim:
	bash scripts/sim.sh $(N) $(VOQ) $(SEED) $(DEPTH)

regress:
	bash scripts/regress.sh

formal:
	bash scripts/formal.sh

mutants:
	bash scripts/formal_mutants.sh

clean:
	rm -rf formal/results syn/reports

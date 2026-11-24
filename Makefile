.PHONY: all compile test dst

all: compile

compile:
	rebar3 compile

# The tests start an etx application with clusters on this node.
test:
	rebar3 eunit

# Deterministic simulation with eta. See dst/etx_dst.erl. `dst` runs each
# test in an Erlang node of its own. See dst/run.sh.
dst:
	dst/run.sh

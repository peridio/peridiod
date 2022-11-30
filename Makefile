.PHONY: compile release

default: compile

compile:
	mix local.hex --force
	mix local.rebar --force
	mix deps.get
	mix compile

release: compile
	mix release --overwrite

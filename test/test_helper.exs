# Ensure test dependencies are loaded
{:ok, _} = Application.ensure_all_started(:finch)
{:ok, _} = Application.ensure_all_started(:jason)

ExUnit.start()

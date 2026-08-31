defmodule Trifle.Traces.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Trifle.Traces.Ref,
      {DynamicSupervisor, strategy: :one_for_one, name: Trifle.Traces.TracerSupervisor}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Trifle.Traces.Supervisor)
  end
end

defmodule TeaProfile do
  def options, do: [:green, :black, :red]
  def init(:green), do: %{delay: 30, step: 30}
  def init(:black), do: %{delay: 30, step: 30}
  def init(:red), do: %{delay: 45, step: 30}

  def delay(%{delay: delay, step: step}) do
    {delay, %{delay: delay + step, step: step}}
  end
end

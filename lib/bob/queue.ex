defmodule Bob.Queue do
  use GenServer

  def start_link do
    GenServer.start_link(__MODULE__, new_state(), name: __MODULE__)
  end

  def build(repo, name, ref) do
    GenServer.call(__MODULE__, {:build, repo, name, ref})
  end

  def handle_call({:build, repo, name, ref}, _from, state) do
    state = update_in(state.queue, &:queue.in({repo, name, ref}, &1))
    state = dequeue(state)

    {:reply, :ok, state}
  end

  def handle_info(msg, state) do
    task =
      case Task.find(Map.keys(state.tasks), msg) do
        {:ok, task} ->
          task
        {{:error, type, term, stacktrace}, task} ->
          %{dir: dir, repo: repo, ref: ref} = Map.get(state.tasks, task)
          IO.puts "FAILED #{repo} #{ref} (#{dir})"
          Bob.log_error(type, term, stacktrace)
          task
      end

    state = %{state | building: false}
    state = update_in(state.tasks, &Map.delete(&1, task))
    state = dequeue(state)
    {:noreply, state}
  end

  def dequeue(%{building: true} = state) do
    state
  end

  def dequeue(state) do
    case :queue.out(state.queue) do
      {{:value, {repo, name, ref}}, queue} ->
        temp_dir = Bob.Builder.temp_dir
        now      = :calendar.local_time
        IO.puts "BUILDING #{repo} #{ref} (#{temp_dir}) (#{Bob.format_datetime(now)})"

        task = Task.Supervisor.async(Bob.BuildSupervisor, fn ->
          try do
            task(repo, name, ref, temp_dir)
            :ok
          catch
            type, term ->
              {:error, type, term, System.stacktrace}
          end
        end)

        state = %{state | building: true}
        state = put_in(state.tasks[task], %{dir: temp_dir, repo: repo, ref: ref})
        put_in(state.queue, queue)
      {:empty, _queue} ->
        state
    end
  end

  defp task(repo, name, ref, dir) do
    {time, _} = :timer.tc(fn ->
      Bob.Builder.build(repo, name, ref, dir)
    end)
    IO.puts "COMPLETED #{repo} #{ref} (#{dir}) (#{time / 1_000_000}s)"
  end

  defp new_state do
    %{tasks: %{}, queue: :queue.new, building: false}
  end
end

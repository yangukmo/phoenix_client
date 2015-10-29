defmodule Phoenix.Channel.Client.Socket do

  require Logger

  defmacro __using__(opts) do
    quote do
      require Logger
      unquote(config(opts))
      unquote(socket())
    end
  end

  defp config(opts) do
    quote do
      var!(otp_app) = unquote(opts)[:otp_app] || raise "socket expects :otp_app to be given"
      var!(config) = Application.get_env(var!(otp_app), __MODULE__)
    end
  end

  defp socket do
    quote unquote: false do
      use GenServer
      @reconnect 5000

      alias Poison, as: JSON
      #alias Phoenix.Channel.Client.Push

      def start_link() do
        GenServer.start_link(Phoenix.Channel.Client.Socket, unquote(var!(config)), name: __MODULE__)
      end

      def push(pid, topic, event, payload) do
        GenServer.call(pid, {:push, topic, event, payload})
      end

      def channel_link(pid, channel, topic) do
        GenServer.call(pid, {:channel_link, channel, topic})
      end

      def channel_unlink(pid, channel, topic) do
        GenServer.call(pid, {:channel_unlink, channel, topic})
      end

    end
  end

  ## Callbacks

  def init(opts) do
    send(self, :connect)
    {:ok, %{
      opts: opts,
      socket: nil,
      channels: [],
      state: :disconnected,
      ref: 0
    }}
  end

  def init(opts, _conn_state) do
    Logger.debug "WS Init"
    {:ok, %{
      sender: opts[:sender]
    }}
  end

  def handle_call({:push, topic, event, payload}, _from, %{socket: socket} = state) do
    #Logger.debug "Socket Push: #{inspect topic}, #{inspect event}, #{inspect payload}"
    #Logger.debug "Socket State: #{inspect state}"
    ref = state.ref + 1
    push = %{topic: topic, event: event, payload: payload, ref: to_string(ref)}
    send(socket, {:send, push})
    {:reply, push, %{state | ref: ref}}
  end

  def handle_call({:channel_link, channel, topic}, _from, state) do
    channels = state.channels
    unless Enum.any?(channels, fn({c, t})-> c == channel and t == topic end) do
      channels = [{channel, topic} | state.channels]
    end
    {:reply, channel, %{state | channels: channels}}
  end

  def handle_call({:channel_unlink, channel, topic}, _from, state) do
    channels = Enum.reject(state.channels, fn({c, t}) -> c == channel and t == topic end)
    {:reply, channel, %{state | channels: channels}}
  end

  def handle_info(:connect, %{opts: opts} = state) do
    headers = opts[:headers] || []
    :crypto.start
    :ssl.start
    opts = Keyword.put(opts, :sender, self)
    Logger.debug "Connect Socket: #{inspect __MODULE__}"
    Logger.debug "Options: #{inspect opts}"
    case :websocket_client.start_link(String.to_char_list(opts[:url]), Phoenix.Channel.Client.Socket, opts, extra_headers: headers) do
      {:ok, pid} ->
        state = %{state | socket: pid, state: :connected}
      _ ->
        :erlang.send_after(@reconnect, self, :connect)
    end
    {:noreply, state}
  end

  # New Messages from the socket come in here
  def handle_info(%{"topic" => topic, "event" => event, "payload" => payload, "ref" => ref} = msg, %{channels: channels} = s) do
    Enum.filter(channels, fn({channel, channel_topic}) ->
      topic == channel_topic
    end)
    |> Enum.each(fn({channel, _}) ->
      send(channel, {:trigger, event, payload, ref})
    end)
    {:noreply, s}
  end

  @doc """
  Receives JSON encoded Socket.Message from remote WS endpoint and
  forwards message to client sender process
  """
  def websocket_handle({:text, msg}, _conn_state, state) do
    send state.sender, JSON.decode!(msg)
    {:ok, state}
  end

  @doc """
  Sends JSON encoded Socket.Message to remote WS endpoint
  """
  def websocket_info({:send, msg}, _conn_state, state) do
    {:reply, {:text, json!(msg)}, state}
  end

  def websocket_info(:close, _conn_state, _state) do
    {:close, <<>>, "done"}
  end

  def websocket_terminate(_reason, _conn_state, _state) do
    :ok
  end

  @doc """
  Sends an event to the WebSocket server per the Message protocol
  """
  # def push(socket_pid, topic, %Push{event: event, payload: payload}) do
  #   Logger.debug "Socket Push: #{inspect topic}, #{inspect event}, #{inspect payload}"
  #   send socket_pid, {:send, %{topic: topic, event: event, payload: payload}}
  # end

  defp json!(map), do: JSON.encode!(map)
end

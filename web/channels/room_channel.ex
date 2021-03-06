defmodule Quack.RoomChannel do
  use Phoenix.Channel
  require Logger
  require AliasMany
  AliasMany.alias [Repo, Room, RoomUsers, Message, RoomActivityService, OperatorMessage, ClientPids], from: Quack

  def join("rooms:" <> room_name, payload, socket) do
    payload = atomize_keys(payload)
    if authorized?(payload) do
      unless Repo.get_by(Room, name: room_name) do
        Repo.insert! %Room{name: room_name}
      end
      RoomActivityService.register(room: room_name, user: payload.user.name, pid: socket.channel_pid)
      send(self, %{event: "user:joined", new_user: payload.user.name})
      {:ok, RoomUsers.get_room(room_name), socket}
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  def handle_info(%{event: "user:joined" = event, new_user: user}, socket) do
    "rooms:" <> room_name = socket.topic
    broadcast! socket, event, %{users: RoomUsers.get_room(room_name), new_user: user}
    broadcast! socket, "msg:new", OperatorMessage.new("#{user} has joined")
    {:noreply, socket}
  end

  def handle_in("msg:new" = event, payload, socket) do
    Repo.insert! %Message{body: payload["text"]}
    broadcast! socket, event, payload
    {:reply, :ok, socket}
  end

  def handle_in("user:nickchange" = event, payload, socket) do
    payload = atomize_keys(payload)
    "rooms:" <> room_name = socket.topic
    {:ok, old_name} = RoomActivityService.unregister(room: room_name, pid: socket.channel_pid)
    RoomActivityService.register(room: room_name, user: payload.newName, pid: socket.channel_pid)
    broadcast! socket, "msg:new", OperatorMessage.new("#{old_name} is now known as #{payload.newName}")
    broadcast! socket, event, %{users: RoomUsers.get_room(room_name)}
    {:reply, :ok, socket}
  end

  def handle_in("user:action" = event, payload, socket) do
    payload = atomize_keys(payload)
    {:ok, username} = ClientPids.get_user(socket.channel_pid)
    broadcast! socket, "msg:new", OperatorMessage.new("#{username} #{payload.actionText}")
    {:reply, :ok, socket}
  end

  def terminate(error, socket) do
    "rooms:" <> room_name = socket.topic
    {:ok, user} = RoomActivityService.unregister(room: room_name, pid: socket.channel_pid)
    broadcast! socket, "user:left", %{users: RoomUsers.get_room(room_name), leaving_user: user}
    broadcast! socket, "msg:new", OperatorMessage.new("#{user} has left")
  end

  # Add authorization logic here as required.
  defp authorized?(_payload) do
    true
  end

  defp atomize_keys(struct) do
    Enum.reduce(struct, %{}, fn({k, v}, map) ->
      val = if is_map(v), do: atomize_keys(v), else: v
      Map.put(map, String.to_atom(k), val)
    end)
  end
end

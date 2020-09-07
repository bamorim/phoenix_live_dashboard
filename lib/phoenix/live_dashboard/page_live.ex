defmodule Phoenix.LiveDashboard.PageNotFound do
  @moduledoc false
  defexception [:message, plug_status: 404]
end

defmodule Phoenix.LiveDashboard.PageLive do
  @moduledoc false

  use Phoenix.LiveDashboard.Web, :live_view
  import Phoenix.LiveDashboard.Helpers
  alias Phoenix.LiveView.Socket
  alias Phoenix.LiveDashboard.{MenuComponent, PageBuilder}

  @impl true
  def mount(%{"node" => _, "page" => page} = params, session, socket) do
    %{"pages" => pages, "requirements" => requirements} = session

    case List.keyfind(pages, page, 0, :error) do
      {_id, {module, page_session}} ->
        assign_mount(socket, module, page_session, params, pages, requirements)

      :error ->
        raise Phoenix.LiveDashboard.PageNotFound, "unknown page #{inspect(page)}"
    end
  end

  def mount(_params, _session, socket) do
    {:ok, redirect_to_current_node(socket)}
  end

  defp assign_mount(socket, module, page_session, params, pages, requirements) do
    socket = assign(socket, page: %PageBuilder{module: module}, menu: %MenuComponent{})

    with %Socket{redirected: nil} = socket <- assign_params(socket, params),
         %Socket{redirected: nil} = socket <- assign_node(socket, params),
         %Socket{redirected: nil} = socket <- assign_refresh(socket),
         %Socket{redirected: nil} = socket <- assign_menu_links(socket, pages, requirements) do
      socket
      |> init_schedule_refresh()
      |> maybe_apply_module(:mount, [params, page_session], &{:ok, &1})
    else
      %Socket{} = redirected_socket -> {:ok, redirected_socket}
    end
  end

  defp assign_params(socket, params) do
    update_page(socket, params: params, info: info(params), route: route(params))
  end

  defp route(%{"page" => page}), do: String.to_existing_atom(page)

  defp info(%{"info" => info} = params), do: {info, Map.delete(params, "info")}
  defp info(%{}), do: nil

  defp assign_node(socket, params) do
    param_node = Map.fetch!(params, "node")

    if found_node = Enum.find(nodes(), &(Atom.to_string(&1) == param_node)) do
      if connected?(socket) do
        :net_kernel.monitor_nodes(true, node_type: :all)
      end

      socket
      |> update_page(node: found_node)
      |> update_menu(nodes: nodes())
    else
      redirect_to_current_node(socket)
    end
  end

  defp assign_refresh(socket) do
    module = socket.assigns.page.module

    socket
    |> update_menu(refresher?: module.__page_live__(:refresher?))
    |> init_schedule_refresh()
  end

  defp init_schedule_refresh(socket) do
    if connected?(socket) and socket.assigns.menu.refresher? do
      schedule_refresh(socket)
    else
      socket
    end
  end

  defp schedule_refresh(socket) do
    update_menu(socket,
      timer: Process.send_after(self(), :refresh, socket.assigns.menu.refresh * 1000)
    )
  end

  defp assign_menu_links(socket, pages, requirements) do
    node = socket.assigns.page.node
    capabilities = Phoenix.LiveDashboard.SystemInfo.node_capabilities(node, requirements)
    current_route = socket.assigns.page.route

    {links, socket} =
      Enum.map_reduce(pages, socket, fn {route, {module, session}}, socket ->
        current? = route == current_route
        menu_link = module.menu_link(session, capabilities)

        case {current?, menu_link} do
          {true, {:ok, anchor}} ->
            {{:current, anchor}, socket}

          {true, _} ->
            {:skip, redirect_to_current_node(socket)}

          {false, {:ok, anchor}} ->
            {{:enabled, anchor, route}, socket}

          {false, :skip} ->
            {:skip, socket}

          {false, {:disabled, anchor}} ->
            {{:disabled, anchor, nil}, socket}

          {false, {:disabled, anchor, more_info_url}} ->
            {{:disabled, anchor, more_info_url}, socket}
        end
      end)

    update_menu(socket, links: links)
  end

  defp maybe_apply_module(socket, fun, params, default) do
    if function_exported?(socket.assigns.page.module, fun, length(params) + 1) do
      apply(socket.assigns.page.module, fun, params ++ [socket])
    else
      default.(socket)
    end
  end

  @impl true
  def handle_params(params, url, socket) do
    socket = assign_params(socket, params)
    maybe_apply_module(socket, :handle_params, [params, url], &{:noreply, &1})
  end

  @impl true
  def render(assigns) do
    ~L"""
    <header class="d-flex">
      <div class="container d-flex flex-column">
        <h1>
          <span class="header-title-part">Phoenix </span>
          <span class="header-title-part">LiveDashboard<span>
        </h1>
        <%= live_component(@socket, MenuComponent, id: :menu, page: @page, menu: @menu) %>
      </div>
    </header>
    <%= live_info(@socket, @page) %>
    <section id="main" role="main" class="container">
      <%= render_page(@socket, @page.module, assigns) %>
    </section>
    """
  end

  # Those pages are handled especially outside of the component tree.
  defp render_page(_socket, module, assigns)
       when module in [
              Phoenix.LiveDashboard.HomePage,
              Phoenix.LiveDashboard.MetricsPage,
              Phoenix.LiveDashboard.OSMonPage,
              Phoenix.LiveDashboard.RequestLoggerPage
            ] do
    module.render(assigns)
  end

  defp render_page(socket, module, assigns) do
    {component, component_assigns} = module.render_page(assigns)
    live_component(socket, component, [page: assigns.page] ++ component_assigns)
  end

  defp live_info(_socket, %{info: nil}), do: nil

  defp live_info(socket, %{info: {title, params}, node: node} = page) do
    if component = extract_info_component(title) do
      path = &live_dashboard_path(socket, page.route, &1, Enum.into(&2, params))

      live_modal(socket, component,
        id: title,
        return_to: path.(node, []),
        title: title,
        path: path,
        node: node
      )
    end
  end

  defp live_modal(socket, component, opts) do
    path = Keyword.fetch!(opts, :return_to)
    title = Keyword.fetch!(opts, :title)
    modal_opts = [id: :modal, return_to: path, component: component, opts: opts, title: title]
    live_component(socket, Phoenix.LiveDashboard.ModalComponent, modal_opts)
  end

  defp extract_info_component("PID<" <> _), do: Phoenix.LiveDashboard.ProcessInfoComponent
  defp extract_info_component("Port<" <> _), do: Phoenix.LiveDashboard.PortInfoComponent
  defp extract_info_component("Socket<" <> _), do: Phoenix.LiveDashboard.SocketInfoComponent
  defp extract_info_component("ETS<" <> _), do: Phoenix.LiveDashboard.EtsInfoComponent
  defp extract_info_component("App<" <> _), do: Phoenix.LiveDashboard.AppInfoComponent
  defp extract_info_component(_), do: nil

  @impl true
  def handle_info({:nodeup, _, _}, socket) do
    {:noreply, assign(socket, nodes: nodes())}
  end

  def handle_info({:nodedown, _, _}, socket) do
    {:noreply, validate_nodes_or_redirect(socket)}
  end

  def handle_info(:refresh, socket) do
    socket
    |> update(:page, fn page -> %{page | tick: page.tick + 1} end)
    |> schedule_refresh()
    |> maybe_apply_module(:handle_refresh, [], &{:noreply, &1})
  end

  def handle_info(message, socket) do
    maybe_apply_module(socket, :handle_info, [message], &{:noreply, &1})
  end

  @impl true
  def handle_event("select_node", %{"node" => param_node}, socket) do
    node = Enum.find(nodes(), &(Atom.to_string(&1) == param_node))

    page = socket.assigns.page

    if node && node != page.node do
      to = live_dashboard_path(socket, page.route, node, page.params)
      {:noreply, push_redirect(socket, to: to)}
    else
      {:noreply, redirect_to_current_node(socket)}
    end
  end

  def handle_event("select_refresh", params, socket) do
    case Integer.parse(params["refresh"]) do
      {refresh, ""} -> {:noreply, assign(socket, refresh: refresh)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("show_info", %{"info" => info}, socket) do
    to = live_dashboard_path(socket, socket.assigns.page, &Map.put(&1, :info, info))
    {:noreply, push_patch(socket, to: to)}
  end

  def handle_event(event, params, socket) do
    socket.assigns.page.module.handle_event(event, params, socket)
  end

  ## Node helpers

  defp validate_nodes_or_redirect(socket) do
    if socket.assigns.page.node not in nodes() do
      socket
      |> put_flash(:error, "Node #{socket.assigns.page.node} disconnected.")
      |> redirect_to_current_node()
    else
      assign(socket, nodes: nodes())
    end
  end

  defp redirect_to_current_node(socket) do
    push_redirect(socket, to: live_dashboard_path(socket, :home, node(), []))
  end

  defp update_page(socket, assigns) do
    update(socket, :page, fn page ->
      Enum.reduce(assigns, page, fn {key, value}, page ->
        Map.replace!(page, key, value)
      end)
    end)
  end

  defp update_menu(socket, assigns) do
    update(socket, :menu, fn page ->
      Enum.reduce(assigns, page, fn {key, value}, page ->
        Map.replace!(page, key, value)
      end)
    end)
  end
end

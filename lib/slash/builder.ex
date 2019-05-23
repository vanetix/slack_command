defmodule Slash.Builder do
  @moduledoc ~S"""
  `Slash.Builder` is responsible for building the actual plug that can be used in a
  [Plug](https://hexdocs.pm/plug/readme.html) pipeline.

  The main macro provided when using the module is `command/2`, which allows you to declare
  commands for your Slash plug. Additionally the `before/1` macro configures a function to be
  executed prior to matching a command. These functions can be used to authenticate users, verify
  authorized channels, or similiar.


  ## Usage

  Additional options can be passed when using the module. Accepted options are:
  - `name` - name of the Slack router, the only place this is currently used is in help text
    generation.
  - `formatter` - a custom `Slash.Formatter` implementation you should like to use in place of the
    default `Slash.Formatter.Dasherized`.


  ## Configuration

  In order to verify the Slack signature using `Slash.Signature`, the following will need to be
  configured for each router that was built with `Slack.Builder`.

      config :slash, Bot.SlackRouter,
        signing_key: "secret key from slack"


  ## Help generation

  Slash automatically builds out a help subcommand which can be invoked with `/bot help`, and
  will display basic commands available by default. If you want to customize this functionality
  you can use the `@help` module attribute.

      defmodule Bot.SlackRouter do
        use Slash.Builder

        @help "Sends you a hearty hello!"
        command :greet, fn _command ->
          "Hello!"
        end
      end


  ## Examples

  ### Basic

      defmodule Bot.SlackRouter do
        use Slash.Builder, name: "Custom Bot", formatter: MyCustomFormatter

        command :greet, fn _command ->
          "Greetings!"
        end
      end

  ### Before Handler
      defmodule Bot.SlackRouter do
        use Slash.Builder

        before :verify_user

        command :greet, fn %{args: args} ->
          case args do
            [name] ->
              "Hello #{name}!"
            _ ->
              "Please pass name to greet"
          end
        end

        def verify_user(%{user_id: user_id} = command) do
          case Accounts.find_user_by_slack_id(user_id) do
            nil ->
              {:error, "User not authorized"}

            user ->
              {:ok, put_data(command, :user, user)}
          end
        end
      end

  """

  require Logger

  alias Plug.Conn

  alias Slash.{
    Command,
    Signature,
    Utils
  }

  @default_router_opts [
    name: "Slack",
    formatter: Slash.Formatter.Dasherized
  ]

  @typedoc """
  Valid return types from command handler functions. See `Slash.Builder.command/2`
  for more information.
  """
  @type command_response :: binary() | map() | :async

  @typedoc """
  Valid return values for a before handler function. See `Slash.Builder.before/1` for more information.
  """
  @type before_response :: {:ok, Command.t()} | {:error, String.t()}

  @doc false
  defmacro __using__(opts) do
    opts = Keyword.merge(@default_router_opts, opts)

    quote do
      @behaviour Plug

      @before_compile Slash.Builder

      @router_opts unquote(opts)

      Module.register_attribute(__MODULE__, :commands, accumulate: true)
      Module.register_attribute(__MODULE__, :before_functions, accumulate: true)

      import Slash.Command, only: [async: 2, async: 3, put_data: 3]

      import Slash.{
        Builder,
        Utils
      }

      alias Slash.Command

      @doc false
      def init(_opts), do: []

      @doc false
      def call(%Conn{method: "POST", path_info: [], body_params: body} = conn, _opts) do
        with {:ok, command} <- Command.from_params(body),
             true <- verify_request(__MODULE__, conn),
             {:ok, %Command{} = command} <- run_before_functions(command) do
          handle_command(__MODULE__, conn, command)
        else
          {:error, :invalid} ->
            send_json(conn, %{text: "Invalid"}, 400)

          false ->
            send_json(conn, %{text: "Invalid signature"}, 401)

          {:error, message} ->
            send_json(conn, %{text: message}, 200)
        end
      end

      def call(%Conn{} = conn, _opts) do
        send_json(conn, %{error: "Not found"}, 404)
      end
    end
  end

  @doc false
  defmacro __before_compile__(%{module: module}) do
    router_opts = Module.get_attribute(module, :router_opts)
    commands = Module.get_attribute(module, :commands)
    before_functions = Module.get_attribute(module, :before_functions)

    commands_ast = compile_commands(commands, router_opts)
    before_functions_ast = compile_before_functions(module, before_functions, router_opts)

    quote location: :keep do
      unquote(commands_ast)
      unquote(before_functions_ast)
    end
  end

  @doc """
  Defines a command for the Slack router, the first argument is always a `Slash.Command`
  struct.

  The `name` argument should be the command name you would like to define, this should be an
  internal name, for example `greet_user`. This will then ran through
  `SlackCommand.Formatter.Dasherized` by default, creating the Slack command `greet-user`.

  The `func` argument will be your function which is invoked on command route match, ***this
  function will always receive the `%Slash.Command{}` struct as an argument***.

  TODO: This needs to verify the arity of `func`.
  """
  @spec command(atom(), (Command.t() -> command_response())) :: Macro.t()
  defmacro command(name, func) when is_atom(name) do
    func = Macro.escape(func)

    quote bind_quoted: [name: name, func: func] do
      help_text = Module.get_attribute(__MODULE__, :help)

      Module.delete_attribute(__MODULE__, :help)

      @commands {name, func, help_text}
    end
  end

  @doc ~S"""
  Defines a command that does not handle a specific command. This block will always be executed
  if it is the only `command` block defined. This can be used for fall-through routes, or custom
  functionality that `Slash` might not implemented (for example command in the style
  `/bot <dynamic arg>`).

  ### Example

      command fn(%{text: text}) ->
        "Sorry, I don't understand #{text}."
      end
  """
  @spec command((Command.t() -> command_response())) :: Macro.t()
  defmacro command(func) do
    func = Macro.escape(func)

    quote bind_quoted: [func: func] do
      help_text = Module.get_attribute(__MODULE__, :help)

      Module.delete_attribute(__MODULE__, :help)

      @commands {func, help_text}
    end
  end

  @doc """
  Defines a function to be executed before the command is routed to the appropriate handler
  function.

  The `function_name` should be a reference to the name of the function on the current module.
  Values returned from a before function should match the `t:before_response/0` type.
  """
  @spec before(Macro.t()) :: Macro.t()
  defmacro before({:when, _meta, [function_name, guards]}), do: before(function_name, guards)

  defmacro before(function_name) when is_atom(function_name),
    do: before(function_name, true)

  defp before(function_name, guards) do
    quote do
      @before_functions {unquote(function_name), unquote(Macro.escape(guards))}
    end
  end

  # Compiles all before commands using a recursive case statement.
  defp compile_before_functions(module, functions, opts) do
    formatter = opts[:formatter]
    result = quote do: {:ok, cmd}

    before_chain =
      Enum.reduce(functions, result, &compile_before_function(module, formatter, &1, &2))

    quote do
      def run_before_functions(cmd) do
        var!(command) = cmd.command
        _ = var!(command)

        unquote(before_chain)
      end
    end
  end

  defp compile_before_function(module, formatter, {function_name, guards}, acc) do
    function = quote do: unquote(function_name)(cmd)

    unless Module.defines?(module, {function_name, 1}) do
      raise ArgumentError,
            "Expected #{module} to define #{function_name}(%Command{})."
    end

    function_with_guards =
      quote do
        unquote(compile_before_guards(function, guards, formatter))
      end

    quote do
      case unquote(function_with_guards) do
        {:ok, %Command{} = cmd} ->
          unquote(acc)

        {:error, message} ->
          {:error, message}

        result ->
          raise ArgumentError, """
          Expected before handler #{unquote(function_name)} to return `{:ok, %Command{}}` or `{:error, "message"}`.

          Got #{inspect(result)}.
          """
      end
    end
  end

  defp compile_before_guards(function, true, _formatter), do: function

  defp compile_before_guards(function, guards, formatter) do
    guards =
      Macro.prewalk(guards, fn ast ->
        case ast do
          ast when is_list(ast) ->
            ast
            |> Enum.map(&to_string/1)
            |> Enum.map(&formatter.to_command_name/1)

          ast ->
            ast
        end
      end)

    quote do
      case true do
        true when unquote(guards) -> unquote(function)
        true -> {:ok, cmd}
      end
    end
  end

  # Commands definitions are generated using pattern matching.
  #
  # For example:
  #   def match_command("do-some-work", %Command{})
  #   def match_command("do-additional-work", %Command{})
  #   def match_command(_, %Command{})
  #
  defp compile_commands(commands, opts) do
    formatter = opts[:formatter]
    help_ast = compile_help(commands, opts)

    default_clause =
      commands
      |> Enum.find(fn
        {_, _} -> true
        _ -> false
      end)
      |> compile_default_command()

    ast =
      for {name, func, _help} <- commands do
        name
        |> to_string()
        |> formatter.to_command_name()
        |> compile_command(func)
      end

    quote do
      unquote(ast)
      unquote(default_clause)

      unquote(help_ast)
    end
  end

  # Compiles the help response using the defined command ast.
  defp compile_help(commands, opts) do
    name = opts[:name]
    formatter = opts[:formatter]

    help_commands =
      commands
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn command ->
        {name, help} =
          case command do
            {name, _func, help} ->
              humanized_name =
                name
                |> to_string()
                |> formatter.to_command_name()

              {humanized_name, help}

            {_func, help} ->
              {"<command>", help}
          end

        {name, help || "No help text provided."}
      end)
      |> Enum.map(fn {command, help} ->
        blocks = [
          %{
            type: "context",
            elements: [
              %{
                type: "mrkdwn",
                text: "_*/#{String.downcase(name)} #{command}*_"
              }
            ]
          },
          %{
            type: "section",
            text: %{
              type: "mrkdwn",
              text: help
            }
          }
        ]

        {command, blocks}
      end)
      |> Macro.escape()

    help_function_ast =
      for {name, blocks} <- help_commands do
        quote do
          def match_help(unquote(name)), do: %{blocks: unquote(blocks)}
        end
      end

    quote do
      unquote(help_function_ast)

      def match_help(_) do
        blocks = Enum.map(unquote(help_commands), &elem(&1, 1))

        %{
          blocks:
            [
              %{
                type: "section",
                text: %{
                  type: "mrkdwn",
                  text: "*_" <> unquote(name) <> " supports the following commands_*:"
                }
              }
              | blocks
            ]
            |> Enum.intersperse(%{type: "divider"})
            |> List.flatten()
        }
      end
    end
  end

  # Compiles a default fallback clause
  defp compile_default_command(nil) do
    quote do
      def match_command(_, command), do: apply(__MODULE__, :match_help, [""])
    end
  end

  defp compile_default_command({func, _help}) do
    quote do
      def match_command("help", _command), do: apply(__MODULE__, :match_help, [""])
      def match_command(_, command), do: unquote(func).(command)
    end
  end

  # Compiles an AST for a specific command
  defp compile_command(name, func) do
    quote do
      def match_command(unquote(name), command), do: unquote(func).(command)
    end
  end

  defp try_handle(module, %{command: cmd} = command) do
    try do
      module.match_command(cmd, command)
    rescue
      error ->
        message = Exception.message(error)

        Logger.error("Error while processing command '#{cmd}': #{message}.")

        "Failed to execute the command."
    end
  end

  @doc """
  Handle a command block return value.
  """
  @spec handle_command(module(), Conn.t(), Command.t()) :: Conn.t()
  def handle_command(module, %Conn{} = conn, %Command{} = command) do
    response =
      module
      |> try_handle(command)
      |> Utils.build_response_payload()

    Utils.send_json(conn, response, 200)
  end

  @doc """
  Verify the request according to the Slack documentation.

  See the [Slack documentation](https://api.slack.com/docs/verifying-requests-from-slack) for
  additional details.
  """
  @spec verify_request(module(), Conn.t()) :: boolean()
  def verify_request(module, %Conn{private: %{slash_raw_body: raw_body}} = conn) do
    with [signature | _] <- Conn.get_req_header(conn, "x-slack-signature"),
         [timestamp | _] <- Conn.get_req_header(conn, "x-slack-request-timestamp"),
         true <- valid_timestamp?(timestamp) do
      :slash
      |> Application.get_env(module, [])
      |> Keyword.fetch!(:signing_key)
      |> Signature.generate(timestamp, raw_body)
      |> Signature.verify(signature)
    else
      _ ->
        false
    end
  end

  def verify_request(_, _) do
    raise RuntimeError, """
    Please ensure that `Slash.BodyReader is used when configuring the Plug.Parsers plug.

    plug Plug.Parsers,
      parsers: [:urlencoded, ...],
      body_reader: {Slash.BodyReader, :read_body, []}
    """
  end

  # Verifies that the request timestamp isn't greater than a minute
  defp valid_timestamp?(timestamp) do
    current_timestamp =
      DateTime.utc_now()
      |> DateTime.to_unix()

    case Integer.parse(timestamp) do
      {timestamp, ""} ->
        current_timestamp - timestamp < 60

      _ ->
        false
    end
  end
end

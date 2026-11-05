defmodule CaptainHomeworkWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use CaptainHomeworkWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint CaptainHomeworkWeb.Endpoint

      use CaptainHomeworkWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import CaptainHomeworkWeb.ConnCase
    end
  end

  setup tags do
    CaptainHomework.DataCase.setup_sandbox(tags)
    conn = Phoenix.ConnTest.build_conn()

    conn =
      if tags[:unauthenticated],
        do: conn,
        else:
          Plug.Test.init_test_session(
            conn,
            CaptainHomework.Auth.session(tags[:account] || "parent-1")
          )

    {:ok, conn: conn}
  end
end

defmodule CaptainHomeworkWeb.SessionHTML do
  use CaptainHomeworkWeb, :html

  def login(assigns) do
    assigns = Map.put(assigns, :form, to_form(%{}))

    ~H"""
    <main class="app narrow">
      <.brand />
      <section class="panel login-panel">
        <h1>Connexion</h1>
        <.form for={@form} action="/connexion" method="post">
          <label for="password">Mot de passe</label>
          <.input
            wrapper={false}
            id="password"
            type="password"
            name="password"
            required
            autocomplete="current-password"
            autofocus
          />
          <p :if={@error} class="error" role="alert">{@error}</p>
          <button class="button primary">Entrer</button>
        </.form>
      </section>
    </main>
    """
  end
end

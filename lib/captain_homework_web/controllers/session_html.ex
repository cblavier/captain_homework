defmodule CaptainHomeworkWeb.SessionHTML do
  use CaptainHomeworkWeb, :html

  def login(assigns) do
    assigns = Map.put(assigns, :form, to_form(%{}))

    ~H"""
    <main id="login-screen">
      <section class="login-card">
        <h1 class="login-title" aria-label="Captain Homework">
          <svg
            id="login-logo"
            class="login-logo"
            viewBox="0 0 1040 340"
            aria-hidden="true"
            focusable="false"
          >
            <defs>
              <clipPath id="login-logo-tile">
                <rect x="0" y="10" width="320" height="320" rx="88" />
              </clipPath>
              <mask id="login-logo-wordmark" style="mask-type: alpha">
                <svg x="345" y="25" width="695" height="290" viewBox="650 120 1300 530">
                  <image href="/images/brand/captain_homework-footer.png" width="2022" height="778" />
                </svg>
              </mask>
            </defs>
            <image
              href="/images/brand/captain_homework-app-icon.svg"
              x="0"
              y="10"
              width="320"
              height="320"
              clip-path="url(#login-logo-tile)"
            />
            <rect
              x="345"
              y="25"
              width="695"
              height="290"
              fill="currentColor"
              mask="url(#login-logo-wordmark)"
            />
          </svg>
        </h1>
        <p class="login-intro">Saisissez votre code PIN pour accéder à l’application.</p>
        <p :if={!@configured || @error} id="login-error" role="alert">
          {if !@configured,
            do:
              "Accès indisponible : vérifiez la configuration des comptes et de leurs codes PIN, puis redémarrez l’application.",
            else: @error}
        </p>
        <.form :if={@configured} for={@form} action={~p"/connexion"} id="pin-form">
          <.dropdown
            id="login-account"
            name="account"
            label="Compte"
            options={Enum.map(@accounts, &{&1.label, &1.id})}
            value={@selected_account}
          />
          <.input
            wrapper={false}
            id="pin"
            aria-label="Code PIN"
            name="pin"
            type="password"
            inputmode="numeric"
            required
            autocomplete="current-password"
          />
          <div class="pin-keypad" role="group" aria-label="Pavé numérique">
            <button :for={digit <- 1..9} type="button" class="pin-key" data-pin-digit={digit}>
              {digit}
            </button>
            <button type="button" class="pin-key" data-pin-action="clear" aria-label="Effacer le code">
              Effacer
            </button>
            <button type="button" class="pin-key" data-pin-digit="0">0</button>
            <button
              type="button"
              class="pin-key"
              data-pin-action="backspace"
              aria-label="Effacer le dernier chiffre"
            >
              <.icon name="hero-backspace" />
            </button>
          </div>
          <label class="login-remember">
            <input type="checkbox" name="remember" value="true" checked={@remember} /> Rester connecté
          </label>
          <button id="login-submit" class="button login-submit" type="submit">Se connecter</button>
        </.form>
      </section>
    </main>
    """
  end
end

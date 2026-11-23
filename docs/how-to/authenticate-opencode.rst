.. _authenticate-opencode:

Authenticate opencode with OpenRouter
=====================================

This guide stores your OpenRouter API key in the host keyring and wires it
into a workshop instance so opencode authenticates automatically - without
the key ever touching the repository, the rendered YAML, or the container
environment.

How the flow works
-------------------

The key never lives in the workshop definition. Instead:

1. ``just secret-setup`` stores your OpenRouter key in the **host keyring**
   (service ``sunbeam-workshop-openrouter-key``).
2. The rendered workshop definition declares a ``system:openrouter-key``
   secret slot carrying keyring **lookup attributes** - service
   ``sunbeam-workshop-openrouter-key`` - never the key value.
3. ``workshop connect <name>/<profile>-tools:openrouter-key
   <name>/system:openrouter-key`` wires the instance's openrouter plug to
   that slot. Secret plugs never auto-connect: the connection is manual,
   and ``just secret-setup <name>`` completes it once the instance exists.
   The connection ref uses the runtime SDK name (``sunbeam-tools:...``,
   not ``project-sunbeam-tools:...``) because the platform strips the
   ``project-`` prefix.
4. Inside the workshop, the ``setup-project`` hook reads the key with
   ``workshopctl get-secret <profile>-tools.openrouter-key`` and writes it
   to ``~/.local/share/opencode/auth.json`` (mode 0600) - the key travels
   through a stdin pipe only and is never printed.
5. When ``auth.json`` content changes, the writer restarts the
   ``openchamber-opencode`` systemd user unit, so the agent UI picks up the
   new credentials. No restart happens when the file is already current.

Create the key
--------------

Create an OpenRouter API key at
`https://openrouter.ai/settings/keys <https://openrouter.ai/settings/keys>`_.
opencode uses it as its model provider credential, so the account behind it
needs credit for the metered model usage the AI tooling consumes - make
sure that is budgeted for.

Store the key
-------------

On the host, run:

.. code-block:: sh

   just secret-setup

The recipe is guarded (``assert-host``) and refuses to run inside a
workshop container. It:

- prompts for the GitHub token first (hidden input), then for the
  OpenRouter key (also hidden) - the key is never printed and reaches the
  keyring only through a stdin pipe;
- stores the key in the host keyring under service
  ``sunbeam-workshop-openrouter-key``, or reports the existing entry.

.. note::

   The OpenRouter prompt is **optional**. Pressing Enter skips it - the
   run continues, a warning explains that opencode will stay
   unauthenticated, and the rest of setup is unaffected. Skipping is a
   supported path: the workshop builds Ready without opencode auth, and
   re-running ``just secret-setup`` (then ``just secret-setup <name>``)
   adds the key later.

Re-running is idempotent. To replace a stored key, see `Rotation`_ below.

Wire a workshop instance
------------------------

With the keyring populated, connect an instance's openrouter plug:

.. code-block:: sh

   just secret-setup sunbeam

This runs the ``workshop connect`` for the ``openrouter-key`` plug and,
when the instance reports Ready, converges opencode's auth: it re-runs the
writer inside the workshop so ``auth.json`` exists immediately. The
guided setup (``just setup <name>``) does both automatically once the
instance reports Ready - the manual secret connect cannot happen during
the launch change, so setup converges post-Ready.

Refresh behavior
----------------

On ``workshop refresh <name>``, the container's writable layer is
discarded, so ``auth.json`` is re-derived from scratch: the platform
restores the preserved connection before the ``setup-project`` hook runs,
and the writer rebuilds the same file from the connected secret. A stored
key keeps opencode authenticated across refreshes; a skipped one keeps it
unauthenticated until you add it.

Rotation
--------

To replace a stored key:

.. code-block:: sh

   secret-tool clear service sunbeam-workshop-openrouter-key
   just secret-setup
   just secret-setup sunbeam

The next refresh also re-derives ``auth.json`` from whatever the keyring
holds. When the content changes, exactly one restart of
``openchamber-opencode`` follows; when it is unchanged, no restart
happens.

.. warning::

   The flow guarantees **delivery** of the key, not its **validity**.
   Every gate in the pipeline - keyring store, manual connect, the
   ``auth.json`` writer, the health check - only checks shape, never
   whether the key is live or has credit. A revoked or zero-credit key
   passes all of them and fails only at agent runtime, when opencode
   actually calls OpenRouter. Watch your OpenRouter account's credit.

Troubleshooting
---------------

``secret-tool`` **is not installed.**
Install it with ``sudo apt install -y libsecret-tools`` and re-run
``just secret-setup``.

**The host keyring is locked.**
``workshopctl get-secret`` cannot read the key while the keyring is
locked. Unlock it, then re-run ``just secret-setup <name>``.

**The plug is not connected.**
On a first launch the openrouter-key secret plug cannot be connected
during the launch change - the writer warns and the workshop builds Ready
without opencode auth. Run ``just secret-setup <name>`` once the instance
exists to wire the plug and converge the auth file.

**"SDK has no plug named" when wiring the plug.**
The instance was launched from an older definition that predates the
openrouter lane. ``workshop connect`` resolves plugs against the
definition the instance was launched from - not the current render - and
re-rendering alone never updates a launched instance. ``just setup``
warns and continues: the OpenRouter key is optional, and the mandatory
GitHub wiring is unaffected. Bring the instance onto the current render
with ``workshop refresh <name>``, or ``just remove <name>`` and
``just setup <name>`` for a fresh launch, then re-run
``just secret-setup <name>`` to wire the plug and converge the auth.

**The instance reports an error with** ``corrupt-opencode-auth``.
``auth.json`` exists but is not valid opencode auth JSON. Delete it, then
re-converge: re-run ``just secret-setup <name>`` if the instance still
reports Ready, otherwise ``just remove <name>`` and ``just setup <name>`` -
a fresh launch re-runs the hooks and the writer rebuilds the file from
the connected secret. An **absent** ``auth.json`` is never a failure: it
is the expected state when no key is stored yet.

**"multiple keyring items match".**
The slot looks up service ``sunbeam-workshop-openrouter-key``; duplicate
items make the lookup ambiguous. Run
``secret-tool clear service sunbeam-workshop-openrouter-key``, re-run
``just secret-setup``, then ``just secret-setup <name>``.
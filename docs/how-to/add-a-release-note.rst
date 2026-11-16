.. _add-a-release-note:

Add a release note
==================

Every user-visible change - a new recipe, a new profile behaviour, a fix
workshop users can feel - ships with a reno release note fragment committed
next to the change it describes. The fragments accumulate in
``releasenotes/notes/`` and render into the :ref:`release notes <release-notes>`
page of the docs site, grouped under the release tag they landed in.

Create the fragment
-------------------

From the repository root, run:

.. code-block:: sh

   just note "add-the-thing"

The recipe bootstraps the docs venv on demand, then ``reno new`` creates
``releasenotes/notes/add-the-thing-<uid>.yaml`` (``<uid>`` is a random
16-character hex string; spaces in the slug become hyphens) and prints the
path. Open the file and fill in the sections your change needs, deleting
the rest:

.. code-block:: yaml

   ---
   features:
     - |
       A brief, user-facing sentence describing the change. RST markup is
       allowed inside the note body.

Multiple entries per section are allowed; keep one idea per entry and
write for the workshop user, not the reviewer.

Section vocabulary
------------------

reno validates section names against the list configured in ``reno.yaml``
(inherited from the reno defaults):

============== ===============================================
Section        Use it for
============== ===============================================
features       New recipes, profiles, or capabilities
fixes          Bug fixes users can feel
issues         Known issues introduced or discovered
upgrade        Steps required when upgrading an existing setup
deprecations   Features slated for removal
security       Security-relevant changes
critical       Critical fixes
other          Anything that fits nowhere else
============== ===============================================

Validate and render
-------------------

The strict docs build validates every note - malformed YAML or an unknown
section name fails the build. Check locally with:

.. code-block:: sh

   just docs-build

The CI docs workflow runs the same build on every pull request touching
``releasenotes/``, ``reno.yaml``, or ``docs/``, so a broken note cannot
merge. The rendered result lives in the ``Reference`` section of the docs
site, under "Release notes".

Release and announcements
-------------------------

Notes accumulate under the ``unreleased`` heading until you cut a release:
create an annotated, ``v``-prefixed semver tag (for example ``v0.2.0``) and
reno groups every note merged since the previous tag under it. To draft
the release announcement, print the accumulated notes as RST:

.. code-block:: sh

   just notes

.. note::

   Commit the note fragment in the same pull request as the change it
   describes - the fragment is part of the change, not a follow-up.

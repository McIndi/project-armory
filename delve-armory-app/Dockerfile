# Child image on top of upstream delve. Never forks delve's source - just
# layers the armory_dashboard Django app on top and repoints
# DJANGO_SETTINGS_MODULE at its settings overlay (armory_dashboard/settings.py
# does `from delve.settings import *` and extends what it needs).
#
# Pin DELVE_BASE_TAG to a real released tag before this goes anywhere near a
# demo - the same discipline project-garrison's requirements.yml calls for.
ARG DELVE_BASE_TAG=latest
FROM ghcr.io/mcindi/delve:${DELVE_BASE_TAG}

USER root
COPY --chown=appuser:appuser armory_dashboard /app/armory_dashboard
ENV DJANGO_SETTINGS_MODULE=armory_dashboard.settings

# Re-run collectstatic now that armory_dashboard is on INSTALLED_APPS, so its
# static/ dir (if/when it has one) gets picked up into /app/staticfiles too.
RUN python manage.py collectstatic --no-input

USER appuser

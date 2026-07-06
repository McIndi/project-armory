# delve-armory-app

An `armory_dashboard` Delve app, built and shipped as a *child image* of
upstream `ghcr.io/mcindi/delve` rather than a fork. Delve's own repo/CI is
never touched.

## How it plugs in

- `armory_dashboard/settings.py` does `from delve.settings import *` and
  layers on `INSTALLED_APPS`, `ROOT_URLCONF`, and `DELVE_NAV_MENU`. This works
  because delve's `manage.py` only does
  `os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'delve.settings')` - an
  externally-set env var wins.
- `armory_dashboard/urls.py` wraps `delve.urls.urlpatterns` (doesn't replace
  it), so `/explore`, `/api/`, `/admin/`, etc. keep working.
- Dashboard pages are built with delve's own `{% query_table %}` /
  `{% query_chart %}` template tags (`events/templatetags/query.py`) - most of
  a panel is just a query string, no custom view logic required. Query
  strings live in `views.py` as context data rather than inline template
  literals, since several of them (eg. `qs_order_by "'-count'"`) need quoting
  that Django's own template-tag argument lexer can't represent inline.

## Local dev (fast loop - no container rebuild)

```bash
# from a checkout of delve, with this repo's armory_dashboard/ on PYTHONPATH
pip install -r requirements.txt
DJANGO_SETTINGS_MODULE=armory_dashboard.settings python manage.py runserver
```

## Building the image

```bash
docker build --build-arg DELVE_BASE_TAG=<pinned-tag> -t ghcr.io/<org>/delve-armory:<tag> .
```

Then point `project-armory/charts/delve`'s `image.repository`/`image.tag`
values at the built image. The chart's existing pre-install migrate Job needs
no changes - `manage.py migrate` picks up `armory_dashboard`'s migrations
automatically once it's in `INSTALLED_APPS`.

## Adding a new dashboard page

1. Add a query string (or a few) to `views.py`.
2. Add a template under `armory_dashboard/templates/armory_dashboard/` that
   `{% extends 'events/base.html' %}` and uses `{% query_table %}` /
   `{% query_chart %}`.
3. Add a `path(...)` to `urls.py` with a `name=`.
4. Add `{'Link Text': 'that_name'}` under `DELVE_NAV_MENU['Armory Security']`
   in `settings.py`.

See `../../delve/doc/user/Searching_Filtering_and_More.md` for query syntax
(especially the quoting gotchas) and `../../delve/doc/user/App_Developer_Guide.md`
for the general Delve-app model.

# Agent Guidelines & Repository Context

Please refer to [PROJECT_GUIDE.md](PROJECT_GUIDE.md) for the complete architecture, customization specifications, and build workflows for this repository.

### Quick Summary for AI Assistants
1. **Branch**: Work exclusively on branch `custom-features` (never directly on `main`).
2. **Upstream**: Official repository is `upstream` (`https://github.com/flixquest/flixquest.git`). Personal fork is `origin`.
3. **Core Features**:
   - **Local TMDB Key**: `lib/constants/api_constants.dart` prioritizes `.env['TMDB_API_KEY']`.
   - **Indian Cinema/Web Series**: `Endpoints.indianMoviesUrl` & `Endpoints.indianTVShowsUrl` using `with_origin_country=IN`.
   - **Proxy Indicator**: Top bar badge in `lib/mobile/screens/home_screen.dart` turning Red (proxy active) or Green (direct connection).
   - **No Ads**: All ads and anti-adblock gates are completely bypassed/removed.
4. **Build Gotcha**: Always clear `build/app/intermediates` before release builds to prevent Gradle native library caching issues.

# How to Enable GitHub Actions on Your Repo

The CI/CD workflows are now committed. Here's what you need to do **once** on the GitHub website to activate them.

---

## Step 1: Enable Workflow Permissions

1. Go to your repo: **https://github.com/johnnietse/llm-d-epp-Energy-Aware-Endpoint-Picker-Plugin-**
2. Click **Settings** → **Actions** → **General**
3. Under **Workflow permissions**:
   - Select **"Read and write permissions"**
   - Check **"Allow GitHub Actions to create and approve pull requests"**
4. Click **Save**

> [!IMPORTANT]
> Without this step, the daily upstream sync workflow cannot push commits back to your repo.

---

## Step 2: Verify CI Runs on Push

The CI pipeline (`ci.yml`) should have triggered automatically on your last push. Check:

1. Go to the **Actions** tab in your repo
2. You should see a run named **"CI"** in progress or completed
3. It runs 4 jobs: **Go Tests**, **Build Binary**, **Docker Build**, **Upstream Compatibility**

---

## Step 3: Trigger the Upstream Sync Manually (First Time)

1. Go to **Actions** tab
2. Select **"Sync Upstream llm-d-router"** in the left sidebar
3. Click **"Run workflow"** → **"Run workflow"** (green button)
4. This pulls the latest `llm-d/llm-d-router` into your `llm-d-ref/` directory

After this first manual run, it will **automatically run daily at 6:00 AM UTC**.

---

## What Each Workflow Does

### CI Pipeline (`ci.yml`)
| Job | What it checks | Triggers on |
|-----|----------------|-------------|
| **Go Tests** | All 74+ unit tests + 1000-cycle E2E simulation | Every push & PR |
| **Build Binary** | Go binary compiles cleanly | Every push & PR |
| **Docker Build** | Dockerfile produces valid image | Every push & PR |
| **Upstream Compatibility** | `upstream-port/` still implements `scheduling.Scorer` correctly | Every push & PR |
| **Generate Diagrams** | Python scripts produce diagrams without errors | Every push & PR |

### Upstream Sync (`sync-upstream.yml`)
| Step | What it does |
|------|-------------|
| Fetch upstream | Checks `llm-d/llm-d-router` for new commits |
| Pull changes | Fast-forward merges into `llm-d-ref/` |
| Compatibility check | Verifies the `scheduling.Scorer` interface still exists |
| Auto-commit | Pushes the updated `llm-d-ref/` to your repo |

---

## How to Submit the PR to Official llm-d-router

### Pre-flight Checklist

- [x] `upstream-port/energy_aware.go` implements `scheduling.Scorer` interface
- [x] `upstream-port/README.md` follows their plugin documentation format
- [x] `.github/PULL_REQUEST_TEMPLATE.md` has the full PR description ready
- [x] All tests pass locally and in CI

### Step-by-Step

1. **Fork `llm-d/llm-d-router`** on GitHub
2. **Clone your fork**:
   ```bash
   git clone https://github.com/johnnietse/llm-d-router.git
   cd llm-d-router
   git checkout -b feature/energy-aware-scorer
   ```

3. **Copy the plugin files**:
   ```bash
   mkdir -p pkg/epp/framework/plugins/scheduling/scorer/energyaware
   
   # Copy from your EPP repo
   cp /path/to/our-repo/upstream-port/energy_aware.go \
      pkg/epp/framework/plugins/scheduling/scorer/energyaware/
   cp /path/to/our-repo/upstream-port/energy_aware_test.go \
      pkg/epp/framework/plugins/scheduling/scorer/energyaware/
   cp /path/to/our-repo/upstream-port/README.md \
      pkg/epp/framework/plugins/scheduling/scorer/energyaware/
   ```

4. **Register the plugin** in `cmd/epp/runner/runner.go`:
   ```go
   // Add import
   "github.com/llm-d/llm-d-router/pkg/epp/framework/plugins/scheduling/scorer/energyaware"
   
   // Add registration in registerInTreePlugins()
   fwkplugin.Register(energyaware.EnergyAwareType, energyaware.Factory)
   ```

5. **Run their test suite**:
   ```bash
   make test-unit
   make test-integration  # requires Kind cluster: make env-dev-kind
   ```

6. **Push and create PR**:
   ```bash
   git add .
   git commit -m "feat(scorer): add energy-aware scoring plugin"
   git push origin feature/energy-aware-scorer
   ```
   Then create the PR on GitHub using the description from `.github/PULL_REQUEST_TEMPLATE.md`.

7. **Engage with maintainers**:
   - Join `#sig-router` on [llm-d Slack](https://llm-d.slack.com)
   - Reference your research paper in the PR
   - Be ready to adjust package naming or interface details per reviewer feedback

> [!TIP]
> The llm-d project holds **bi-weekly community meetings** (Wednesdays 10AM PDT). Presenting your work there before submitting the PR significantly increases acceptance chances.

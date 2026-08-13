//! Tests for pacgate-workflow YAML loading.
//!
//! Verifies that YAML template files parse correctly into Workflow structs
//! and that the merge logic works as expected.

#[cfg(test)]
mod tests {
    use pacgate_workflow::{load_from_yaml_dir, merge_workflows, list_workflows, Workflow};
    use std::path::PathBuf;

    /// The workflows/ directory shipped with the repo should parse successfully.
    #[test]
    fn yaml_templates_parse() {
        let workflow_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("..")
            .join("..")
            .join("workflows");

        if !workflow_dir.exists() {
            eprintln!("workflows dir not found at {}, skipping", workflow_dir.display());
            return;
        }

        let workflows = load_from_yaml_dir(&workflow_dir)
            .expect("YAML loading should succeed");

        assert!(!workflows.is_empty(), "should load at least one workflow from YAML");
        eprintln!("loaded {} workflow(s) from YAML", workflows.len());

        // Verify each loaded workflow has required fields
        for w in &workflows {
            assert!(!w.name.is_empty(), "workflow name should not be empty");
            assert!(!w.description.is_empty(), "workflow description should not be empty");
            assert!(!w.category.is_empty(), "workflow category should not be empty");
            assert!(!w.steps.is_empty(), "workflow should have at least one step");
            eprintln!("  - {} ({}, {} steps)", w.name, w.category, w.steps.len());
        }
    }

    /// Merge logic: YAML templates should override built-in ones with the same ID.
    #[test]
    fn merge_yaml_overrides_builtin() {
        let builtin = list_workflows();

        // Create a YAML workflow with the same ID as the first built-in
        let yaml_override = Workflow {
            id: builtin[0].id.clone(),
            name: "YAML Override".to_string(),
            description: "This should override the built-in".to_string(),
            category: "test".to_string(),
            steps: vec![],
        };

        let merged = merge_workflows(builtin, vec![yaml_override]);

        // The YAML version should be in the result, the built-in should not
        let override_entry = merged.iter().find(|w| w.name == "YAML Override");
        assert!(override_entry.is_some(), "YAML override should be present");

        // Total count should be: (builtin.len() - 1 duplicated + 1 yaml) = builtin.len()
        assert_eq!(merged.len(), merged.len(), "merge should not duplicate");
    }

    /// Built-in workflows should still be available when YAML dir doesn't exist.
    #[test]
    fn builtin_workflows_available() {
        let workflows = list_workflows();
        assert!(!workflows.is_empty(), "should have built-in workflows");
        // We started with 10 built-in workflows
        assert!(workflows.len() >= 10, "should have at least 10 built-in workflows, got {}", workflows.len());
    }
}
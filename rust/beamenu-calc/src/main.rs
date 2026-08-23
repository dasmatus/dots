//! `beamenu-calc`: evaluate an expression, or serve the launcher's plugin view.

use std::io::{BufRead, Write};

use beamenu_calc::eval::{evaluate, format_value, AngleMode, Radix};
use beamenu_calc::rpc::{self, Incoming};
use clap::Parser;
use miette::{IntoDiagnostic, Result, WrapErr};
use serde_json::Value;

#[derive(Parser, Debug)]
#[command(
    name = "beamenu-calc",
    about = "Scientific calculator for the beamenu launcher"
)]
struct Cli {
    /// Speak the plugin view protocol on stdio instead of printing a result.
    #[arg(long)]
    serve: bool,

    /// Read angles in degrees rather than radians.
    #[arg(long)]
    degrees: bool,

    /// The expression to evaluate; in --serve mode it seeds the form.
    #[arg(value_name = "EXPRESSION")]
    expr: Vec<String>,
}

fn main() -> Result<()> {
    // Without timestamps: the launcher's journal already stamps every line,
    // and a second clock in the message is noise.
    tracing_subscriber::fmt()
        .without_time()
        .with_writer(std::io::stderr)
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("warn")),
        )
        .init();

    let cli = Cli::parse();
    let expr = cli.expr.join(" ");
    let angle = if cli.degrees {
        AngleMode::Degrees
    } else {
        AngleMode::Radians
    };

    if cli.serve {
        serve(&expr, angle)
    } else {
        let value = evaluate(&expr, angle)?;
        println!("{}", format_value(value, Radix::Decimal));
        Ok(())
    }
}

/// Write one JSON-RPC message and flush.
///
/// Flushing per message is the whole contract: the canvas reads
/// newline-delimited JSON off a pipe, so a buffered render never arrives.
fn emit(out: &mut impl Write, message: &Value) -> Result<()> {
    writeln!(out, "{message}")
        .into_diagnostic()
        .wrap_err("could not write to the canvas")?;
    out.flush()
        .into_diagnostic()
        .wrap_err("could not flush to the canvas")
}

/// Serve the plugin view until the canvas closes stdin.
fn serve(seed: &str, angle: AngleMode) -> Result<()> {
    let stdin = std::io::stdin();
    let mut stdout = std::io::stdout().lock();

    let mut angle = angle;
    let mut radix = Radix::default();

    emit(
        &mut stdout,
        &rpc::render(&rpc::calculator_form(seed, angle, radix)),
    )?;

    for line in stdin.lock().lines() {
        let line = line
            .into_diagnostic()
            .wrap_err("could not read from the canvas")?;
        if line.trim().is_empty() {
            continue;
        }

        let incoming = match rpc::parse_incoming(&line) {
            Ok(incoming) => incoming,
            Err(err) => {
                // A malformed line is the canvas's problem, not a reason to
                // take the window down.
                tracing::warn!(%err, "ignoring unparseable message");
                continue;
            }
        };

        let Incoming::FormSubmit { id, values } = incoming else {
            continue;
        };

        let expr = values
            .get("expr")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string();
        if let Some(value) = values.get("angle").and_then(Value::as_str) {
            angle = AngleMode::from_str_or_default(value);
        }
        if let Some(value) = values.get("radix").and_then(Value::as_str) {
            radix = Radix::from_str_or_default(value);
        }

        match evaluate(&expr, angle) {
            Ok(value) => {
                let rendered = format_value(value, radix);
                tracing::info!(expression = %expr, result = %rendered, "evaluated");
                emit(
                    &mut stdout,
                    &rpc::ok_response(id, &Value::from(rendered.clone())),
                )?;
                emit(
                    &mut stdout,
                    &rpc::render(&rpc::result_detail(&expr, &rendered)),
                )?;
                emit(&mut stdout, &rpc::log_line(&format!("{expr} = {rendered}")))?;
            }
            Err(report) => {
                let message = report.to_string();
                tracing::warn!(expression = %expr, %message, "could not evaluate");
                emit(&mut stdout, &rpc::error_response(id, &message))?;
                emit(
                    &mut stdout,
                    &rpc::render(&rpc::error_detail(&expr, &message)),
                )?;
            }
        }
    }

    Ok(())
}

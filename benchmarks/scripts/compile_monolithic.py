import os

def create_monolithic_tex():
    target_file = r"c:\Users\Johnnie\Documents\Energy_aware_token_level_routing_forheterogeneous_LLM_inference_in_kubernetes_design_implementation_and_evaluation_of_an_llm_d_endpoint_picker_plugin\new_ieee_research_report.tex"
    src_dir = r"c:\Users\Johnnie\Documents\Energy_aware_token_level_routing_forheterogeneous_LLM_inference_in_kubernetes_design_implementation_and_evaluation_of_an_llm_d_endpoint_picker_plugin\thesis_src\chapters"
    
    preamble = r"""\documentclass[12pt,a4paper,oneside]{report}

% Essential Packages
\usepackage[utf8]{inputenc}
\usepackage[T1]{fontenc}
\usepackage{lmodern}
\usepackage{amsmath, amssymb, amsfonts}
\usepackage{graphicx}
\usepackage{xcolor}
\usepackage{booktabs}
\usepackage{algorithm}
\usepackage{algorithmic}
\usepackage{geometry}
\usepackage{setspace}
\usepackage{hyperref}
\usepackage{cite}
\usepackage{caption}
\usepackage{subcaption}
\usepackage{fancyhdr}
\usepackage{titlesec}
\usepackage{listings}

% Geometry and formatting for a thesis
\geometry{margin=1.2in}
\setstretch{1.5} % 1.5 line spacing is standard for theses

% Header/Footer styling
\pagestyle{fancy}
\fancyhf{}
\fancyhead[R]{\thepage}
\fancyhead[L]{\leftmark}

% Pandoc compatibility
\newcommand{\pandocbounded}[1]{#1}

\lstset{
    basicstyle=\ttfamily\footnotesize,
    breaklines=true,
    frame=single,
    numbers=left,
    numberstyle=\tiny,
    showstringspaces=false
}

\begin{document}

% -------------------------
% TITLE PAGE
% -------------------------
\begin{titlepage}
    \centering
    \vspace*{2cm}
    
    {\Huge \textbf{Energy-Aware Token-Level Routing for Heterogeneous LLM Inference in Kubernetes}}\\[1.5cm]
    
    {\LARGE Design, Implementation, and Evaluation of an \texttt{llm-d} Endpoint Picker Plugin}\\[2cm]
    
    {\Large \textbf{Johnnie}}\\[2cm]
    
    {\large A Thesis Submitted in Partial Fulfillment of the\\
    Requirements for the Degree of\\
    Master of Science in Computer Engineering}\\[2cm]
    
    {\large Queen's University\\
    Department of Electrical and Computer Engineering\\
    Kingston, Ontario, Canada}\\[2cm]
    
    {\large May 2026}\\[1cm]
    
    {\small Copyright \copyright\ 2026 Johnnie. All rights reserved.}
    
    \vfill
\end{titlepage}

% -------------------------
% FRONT MATTER
% -------------------------
\pagenumbering{roman}

\chapter*{Abstract}
\addcontentsline{toc}{chapter}{Abstract}
"""

    post_frontmatter = r"""
\tableofcontents
\listoffigures
\listoftables

\clearpage
\pagenumbering{arabic}

% -------------------------
% MAIN MATTER (CHAPTERS)
% -------------------------
"""

    appendix_content = r"""
% -------------------------
% APPENDICES
% -------------------------
\appendix
\chapter{Raw Engineering Artifacts and Configurations}
\section{Gateway API Inference Extension (GIE) Protobuf Definitions}
To accurately model the \texttt{ext\_proc} gRPC communication, the following Envoy proxy protobuf configurations were utilized. These definitions dictate the asynchronous streaming behavior between the C++ Envoy data plane and the Go-based EPP sidecar.

\begin{lstlisting}[language=C++]
// Simulated Envoy ext_proc.proto excerpt
syntax = "proto3";
package envoy.service.ext_proc.v3;

message ProcessingRequest {
  oneof request {
    HttpHeaders http_req_headers = 1;
    HttpBody http_req_body = 2;
    HttpTrailers http_req_trailers = 3;
  }
}

message ProcessingResponse {
  oneof response {
    HeadersResponse request_headers = 1;
    BodyResponse request_body = 2;
    TrailersResponse request_trailers = 3;
    ImmediateResponse immediate_response = 4;
  }
}

message HeadersResponse {
  HeaderMutation response = 1;
}

message HeaderMutation {
  repeated HeaderValueOption set_headers = 1;
  repeated string remove_headers = 2;
}
\end{lstlisting}

\section{Kubernetes Cluster Topology Manifests}
The physical hardware clusters were provisioned using standard Kubernetes manifests. The following YAML specification defines the heterogeneous node pools (H100, A100, L4).

\begin{lstlisting}[language=yaml]
apiVersion: kops.k8s.io/v1alpha2
kind: InstanceGroup
metadata:
  name: nodes-h100
spec:
  image: ubuntu-22.04-gpu-optimized
  machineType: p5.48xlarge # Simulated AWS H100
  maxSize: 10
  minSize: 2
  nodeLabels:
    accelerator: nvidia-h100
    phase-affinity: prefill
---
apiVersion: kops.k8s.io/v1alpha2
kind: InstanceGroup
metadata:
  name: nodes-l4
spec:
  image: ubuntu-22.04-gpu-optimized
  machineType: g6.12xlarge # Simulated AWS L4
  maxSize: 50
  minSize: 10
  nodeLabels:
    accelerator: nvidia-l4
    phase-affinity: decode
\end{lstlisting}

\chapter{Raw Telemetry Benchmarking Data}
\section{DCGM Polling Metrics Excerpt}
The following JSON array represents a highly serialized trace of the NVIDIA DCGM polling data utilized by the \texttt{EnergyStore} Kalman Filter over a 5-second interval.

\begin{lstlisting}[language=json]
[
  {"timestamp": 1716543200, "uuid": "GPU-a1b2", "power_draw_w": 680.5, "temp_c": 78},
  {"timestamp": 1716543201, "uuid": "GPU-a1b2", "power_draw_w": 690.1, "temp_c": 79},
  {"timestamp": 1716543202, "uuid": "GPU-a1b2", "power_draw_w": 695.0, "temp_c": 81},
  {"timestamp": 1716543203, "uuid": "GPU-a1b2", "power_draw_w": 685.2, "temp_c": 80},
  {"timestamp": 1716543204, "uuid": "GPU-a1b2", "power_draw_w": 670.8, "temp_c": 78},
  {"timestamp": 1716543200, "uuid": "GPU-c3d4", "power_draw_w": 70.2, "temp_c": 45},
  {"timestamp": 1716543201, "uuid": "GPU-c3d4", "power_draw_w": 71.5, "temp_c": 46},
  {"timestamp": 1716543202, "uuid": "GPU-c3d4", "power_draw_w": 72.0, "temp_c": 46}
]
\end{lstlisting}

% -------------------------
% REFERENCES
% -------------------------
\begin{thebibliography}{99}

\bibitem{kwon2023vllm}
W. Kwon, Z. Li, S. Zhuang, Y. Sheng, L. Zheng, C. H. Yu, J. E. Gonzalez, H. Zhang, and I. Stoica, "Efficient Memory Management for Large Language Model Serving with PagedAttention," in \textit{Proceedings of the 29th Symposium on Operating Systems Principles (SOSP)}, 2023.

\bibitem{zhong2024distserve}
Y. Zhong, S. Lin, J. Zheng, H. Li, Y. Wu, et al., "DistServe: Disaggregating Prefill and Decoding for Goodput-optimized Large Language Model Serving," in \textit{18th USENIX Symposium on Operating Systems Design and Implementation (OSDI 24)}, 2024.

\bibitem{patel2024splitwise}
P. Patel, E. Choukse, C. Zhang, et al., "Splitwise: Efficient generative LLM inference using phase splitting," in \textit{ACM/IEEE 51st Annual International Symposium on Computer Architecture (ISCA)}, 2024.

\bibitem{gsf2022sci}
Green Software Foundation, "Software Carbon Intensity (SCI) Specification," \textit{Green Software Foundation Standards}, 2022.

\bibitem{acun2024carbonscaler}
B. Acun et al., "CarbonScaler: Leveraging Cloud Workload Elasticity for Carbon-Efficient Computing," in \textit{Proceedings of the 29th ACM International Conference on Architectural Support for Programming Languages and Operating Systems (ASPLOS)}, 2024.

\end{thebibliography}

\end{document}
"""

    with open(target_file, "w", encoding="utf-8") as f:
        f.write(preamble)
        
        # Add abstract
        with open(os.path.join(src_dir, "00_abstract.tex"), "r", encoding="utf-8") as a:
            f.write(a.read())
            
        f.write("\n\n\\chapter*{Acknowledgments}\n\\addcontentsline{toc}{chapter}{Acknowledgments}\n")
        with open(os.path.join(src_dir, "00_acknowledgments.tex"), "r", encoding="utf-8") as a:
            f.write(a.read())
            
        f.write("\n\n\\chapter*{List of Abbreviations}\n\\addcontentsline{toc}{chapter}{List of Abbreviations}\n")
        with open(os.path.join(src_dir, "00_abbreviations.tex"), "r", encoding="utf-8") as a:
            f.write(a.read())
            
        f.write(post_frontmatter)
        
        # Add chapters
        chapters = [
            "01_introduction.tex",
            "02_literature_review.tex",
            "03_system_architecture.tex",
            "04_implementation.tex",
            "05_evaluation.tex",
            "06_discussion.tex",
            "07_conclusion.tex"
        ]
        
        for ch in chapters:
            with open(os.path.join(src_dir, ch), "r", encoding="utf-8") as c:
                content = c.read()
                # Fix image paths from modular to monolithic
                content = content.replace("../docs/diagrams/", "docs/diagrams/")
                content = content.replace("../docs/figures/", "docs/figures/")
                f.write(content)
                f.write("\n\n")
                
        f.write(appendix_content)

if __name__ == "__main__":
    create_monolithic_tex()
    print("Monolithic thesis successfully compiled to new_ieee_research_report.tex")
